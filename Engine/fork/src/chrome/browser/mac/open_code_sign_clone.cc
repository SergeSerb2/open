// Copyright 2026 The Open Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "chrome/browser/mac/open_code_sign_clone.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#include <array>
#include <string>
#include <utility>

#include "base/base_paths.h"
#include "base/containers/span.h"
#include "base/files/file_util.h"
#include "base/logging.h"
#include "base/path_service.h"
#include "base/posix/eintr_wrapper.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_view_util.h"
#include "crypto/hash.h"

namespace code_sign_clone_manager {
namespace {

// One fixed clone per install path, not one per version or browser profile.
// Metadata is bounded at 256 bytes; no bundle walk or signature reassessment
// takes place on the reuse path. The metadata read buffer is 256 bytes.
constexpr size_t kMaxIdentityBytes = 256;

base::FilePath Executable(const base::FilePath& bundle,
                          const base::FilePath& name) {
  return bundle.Append("Contents/MacOS").Append(name);
}

std::optional<struct stat> StatExecutable(const base::FilePath& path) {
  struct stat st;
  if (lstat(path.value().c_str(), &st) != 0 || !S_ISREG(st.st_mode)) {
    return std::nullopt;
  }
  return st;
}

std::string Identity(const struct stat& st) {
  // ctime and link count deliberately are not part of the key: creation of
  // the hard link changes both. Size + nanosecond mtime catch in-place cp.
  return "1 " + base::NumberToString(st.st_dev) + " " +
         base::NumberToString(st.st_ino) + " " +
         base::NumberToString(st.st_size) + " " +
         base::NumberToString(st.st_mtimespec.tv_sec) + " " +
         base::NumberToString(st.st_mtimespec.tv_nsec) + "\n";
}

bool PrivateDirectory(const base::FilePath& path) {
  if (mkdir(path.value().c_str(), 0700) != 0 && errno != EEXIST) {
    return false;
  }
  struct stat st;
  // Do not repair permissions. An unavailable cache must use per-run cloning.
  return lstat(path.value().c_str(), &st) == 0 && S_ISDIR(st.st_mode) &&
         st.st_uid == getuid() && (st.st_mode & 0777) == 0700;
}

base::ScopedFD OpenLease(const base::FilePath& path) {
  base::ScopedFD fd(HANDLE_EINTR(open(
      path.value().c_str(), O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600)));
  struct stat st;
  if (!fd.is_valid() || fstat(fd.get(), &st) != 0 || !S_ISREG(st.st_mode) ||
      st.st_uid != getuid() || (st.st_mode & 0777) != 0600 ||
      st.st_nlink != 1) {
    return {};
  }
  return fd;
}

bool LeaseIsCurrent(int fd, const base::FilePath& path) {
  struct stat held;
  struct stat current;
  // Cleanup may retire the install directory between open() and flock(), or
  // while flock() changes lock type. Never protect a new clone with an old,
  // unlinked lease. The cleaner holds EX while renaming and deleting entries.
  return fstat(fd, &held) == 0 && lstat(path.value().c_str(), &current) == 0 &&
         S_ISREG(held.st_mode) && S_ISREG(current.st_mode) &&
         held.st_uid == getuid() && (held.st_mode & 0777) == 0600 &&
         held.st_nlink == 1 && current.st_nlink == 1 &&
         held.st_dev == current.st_dev && held.st_ino == current.st_ino;
}

bool IdentityMatches(const base::FilePath& path, const std::string& identity) {
  base::ScopedFD fd(HANDLE_EINTR(open(
      path.value().c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)));
  struct stat st;
  if (!fd.is_valid() || fstat(fd.get(), &st) != 0 || !S_ISREG(st.st_mode) ||
      st.st_uid != getuid() || identity.size() > kMaxIdentityBytes ||
      st.st_size != static_cast<off_t>(identity.size())) {
    return false;
  }
  std::array<char, kMaxIdentityBytes> saved;
  const auto buffer = base::span(saved).first(identity.size());
  return base::ReadFromFD(fd.get(), buffer) &&
         base::as_string_view(buffer) == identity;
}

bool WriteIdentity(const base::FilePath& path, const std::string& identity) {
  base::ScopedFD fd(HANDLE_EINTR(
      open(path.value().c_str(),
           O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
           0600)));
  return fd.is_valid() && identity.size() <= kMaxIdentityBytes &&
         base::WriteFileDescriptor(fd.get(), identity);
}

bool Matches(const base::FilePath& source_executable,
             const base::FilePath& clone,
             const base::FilePath& name,
             const base::FilePath& metadata,
             const std::string& identity) {
  if (!IdentityMatches(metadata, identity)) {
    return false;
  }
  const auto original = StatExecutable(source_executable);
  const auto linked = StatExecutable(Executable(clone, name));
  return original && linked && Identity(*original) == identity &&
         Identity(*linked) == identity && linked->st_nlink >= 2 &&
         original->st_nlink >= 2 &&
         base::PathExists(clone.Append("Contents/Info.plist"));
}

}  // namespace

std::optional<OpenCodeSignClone> GetOpenCodeSignClone(
    const base::FilePath& source,
    const base::FilePath& executable_name,
    base::FunctionRef<bool(const base::FilePath&,
                           const base::FilePath&,
                           const base::FilePath&)> clone_app) {
  const base::FilePath executable = Executable(source, executable_name);
  const auto original = StatExecutable(executable);
  base::FilePath app_data;
  if (!original || !base::PathService::Get(base::DIR_APP_DATA, &app_data)) {
    return std::nullopt;
  }
  // The cache is independent of CEF's profile/root-cache path. A synthetic or
  // incognito profile must not leave another whole clone for this install.
  const base::FilePath open_data = app_data.Append("Open");
  if (!base::CreateDirectory(open_data)) {
    return std::nullopt;
  }
  const base::FilePath root = open_data.Append("CodeSignClones");
  const auto digest = crypto::hash::Sha256(source.value());
  const base::FilePath install = root.Append(base::HexEncode(digest));
  if (!PrivateDirectory(root) || !PrivateDirectory(install)) {
    return std::nullopt;
  }
  const base::FilePath lease_path = install.Append("lease");
  base::ScopedFD lease = OpenLease(lease_path);
  if (!lease.is_valid() || flock(lease.get(), LOCK_SH | LOCK_NB) != 0 ||
      !LeaseIsCurrent(lease.get(), lease_path)) {
    return std::nullopt;
  }
  const std::string identity = Identity(*original);
  const base::FilePath clone = install.Append("Application.bundle");
  const base::FilePath metadata = install.Append("identity");
  if (Matches(executable, clone, executable_name, metadata, identity)) {
    if (!LeaseIsCurrent(lease.get(), lease_path)) {
      return std::nullopt;
    }
    VLOG(1) << "Open code-sign clone reused: " << clone;
    return OpenCodeSignClone{clone, std::move(lease)};
  }

  // Do not remove a clone that another running browser still needs after a
  // live bundle swap. An unavailable exclusive lease is a cache failure: use
  // Chromium's per-run clone. The next exclusive owner retires the old clone.
  if (flock(lease.get(), LOCK_EX | LOCK_NB) != 0 ||
      !LeaseIsCurrent(lease.get(), lease_path)) {
    return std::nullopt;
  }
  // Another process can have populated the cache while we changed lock type.
  if (!Matches(executable, clone, executable_name, metadata, identity)) {
    if (!base::DeleteFile(metadata) || !base::DeletePathRecursively(clone) ||
        !clone_app(source, clone, executable_name)) {
      base::DeletePathRecursively(clone);
      return std::nullopt;
    }
    const auto after = StatExecutable(executable);
    // Never publish a clone built while the source changed. Leave no stale
    // identity that a later launch could accept after an interrupted copy.
    if (!after || Identity(*after) != identity ||
        !WriteIdentity(metadata, identity) ||
        !Matches(executable, clone, executable_name, metadata, identity)) {
      base::DeleteFile(metadata);
      base::DeletePathRecursively(clone);
      return std::nullopt;
    }
    VLOG(1) << "Open code-sign clone created: " << clone;
  }
  if (flock(lease.get(), LOCK_SH | LOCK_NB) != 0 ||
      !Matches(executable, clone, executable_name, metadata, identity) ||
      !LeaseIsCurrent(lease.get(), lease_path)) {
    return std::nullopt;
  }
  return OpenCodeSignClone{clone, std::move(lease)};
}

}  // namespace code_sign_clone_manager
