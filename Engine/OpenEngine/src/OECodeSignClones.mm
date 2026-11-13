#import <OpenEngine/OEEngine.h>

#include <CommonCrypto/CommonDigest.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <removefile.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#include <string>

namespace {
// Mirror fork 0106: SHA256 of OuterBundlePath's UTF-8 bytes, uppercase hex.
std::string InstallKey(NSString* bundle) {
  NSData* bytes = [bundle dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
  const char* hex = "0123456789ABCDEF";
  std::string key;
  for (unsigned char byte : digest) {
    key += hex[byte >> 4];
    key += hex[byte & 15];
  }
  return key;
}

bool HashName(const std::string& name) {
  if (name.size() != 64) return false;
  return name.find_first_not_of("0123456789ABCDEFabcdef") == std::string::npos;
}

bool CacheEntry(const std::string& name) {
  if (HashName(name)) return true;
  // Interrupted deletions are retried. The producer never opens these names.
  return name.size() == 6 + 64 + 1 + 36 && name.starts_with(".prune-") &&
      HashName(name.substr(6, 64)) && name[70] == '-' &&
      name.substr(71).find_first_not_of("0123456789ABCDEFabcdef-") == std::string::npos;
}

bool PrivateDirectory(int fd) {
  struct stat st;
  return fd >= 0 && fstat(fd, &st) == 0 && S_ISDIR(st.st_mode) &&
      st.st_uid == getuid() && (st.st_mode & 0777) == 0700;
}

bool SameEntry(int parent, const char* name, int fd) {
  struct stat opened, named;
  return fstat(fd, &opened) == 0 &&
      fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 &&
      opened.st_dev == named.st_dev && opened.st_ino == named.st_ino &&
      opened.st_nlink != 0;
}

NSDictionary<NSString*, NSNumber*>* Prune(NSString* path, NSString* bundle) {
  uint64_t removed = 0, leased = 0, failed = 0;
  const std::string current = InstallKey(bundle);
  int root = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (!PrivateDirectory(root)) {
    if (root >= 0) close(root);
    return @{ @"removed": @0, @"leased": @0, @"failed": @(errno != ENOENT) };
  }
  int scan = dup(root);
  DIR* entries = scan >= 0 ? fdopendir(scan) : nullptr;
  if (!entries) {
    if (scan >= 0) close(scan);
    close(root); return @{ @"removed": @0, @"leased": @0, @"failed": @1 };
  }
  // Stream one name at a time: no allocation proportional to the cache size.
  // Each path is one dirent name (NAME_MAX), not an unbounded decoded list.
  while (struct dirent* entry = readdir(entries)) {
    @autoreleasepool {
      std::string name(entry->d_name);
      if (!CacheEntry(name) || name == current) continue;
      int directory = openat(root, name.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
      if (!PrivateDirectory(directory)) { if (directory >= 0) close(directory); ++failed; continue; }
      // O_CREAT also covers a clone interrupted before its lease was created.
      int lease = openat(directory, "lease", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0600);
      struct stat st;
      if (lease < 0 || fstat(lease, &st) != 0 || !S_ISREG(st.st_mode) ||
          st.st_uid != getuid() || (st.st_mode & 0777) != 0600 || st.st_nlink != 1) {
        if (lease >= 0) close(lease);
        close(directory); ++failed; continue;
      }
      if (flock(lease, LOCK_EX | LOCK_NB) != 0) {
        if (errno == EWOULDBLOCK) ++leased; else ++failed;
        close(lease); close(directory); continue;
      }
      if (SameEntry(directory, "lease", lease) && SameEntry(root, name.c_str(), directory)) {
        std::string retired = name.starts_with(".prune-") ? name :
            ".prune-" + name + "-" + NSUUID.UUID.UUIDString.UTF8String;
        // Rename while holding EX, so a new launch at the old name cannot be
        // removed by this worker. Keep EX through deletion. Fork 0106 also
        // revalidates its lease inode after flock before accepting a clone.
        if (retired == name || renameatx_np(root, name.c_str(), root, retired.c_str(), RENAME_EXCL) == 0) {
          // removefile's default traversal unlinks symlinks, never follows them;
          // no CROSS_MOUNT. The slim walk bounds memory to traversal depth.
          if (removefileat(root, retired.c_str(), nullptr,
                           REMOVEFILE_RECURSIVE | REMOVEFILE_RECURSIVE_SLIM) == 0) ++removed;
          else ++failed;
        } else ++failed;
      } else ++failed;
      close(lease);
      close(directory);
    }
  }
  closedir(entries);
  close(root);
  return @{ @"removed": @(removed), @"leased": @(leased), @"failed": @(failed) };
}
}  // namespace

@implementation OEEngine (CodeSignClones)
- (void)pruneUnusedCodeSignClonesWithCompletion:
    (void (^)(NSDictionary<NSString*, NSNumber*>*))completion {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString* bundle = NSBundle.mainBundle.bundlePath;
    NSString* support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                           inDomains:NSUserDomainMask].firstObject.path;
    NSString* path = [support stringByAppendingPathComponent:@"Open/CodeSignClones"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      NSDictionary* counts = Prune(path, bundle);
      dispatch_async(dispatch_get_main_queue(), ^{ completion(counts); });
    });
  });
}
@end
