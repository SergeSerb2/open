// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license in LICENSE.
#include "open/browser/autofill/open_profile_data_impl.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <deque>
#include <map>
#include <set>
#include <string_view>
#include <tuple>
#include "base/command_line.h"
#include "base/containers/span.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/uuid.h"
#include "cef/libcef/browser/request_context_impl.h"
#include "cef/libcef/browser/thread_util.h"
#include "cef/libcef/common/values_impl.h"
#include "chrome/browser/autofill/personal_data_manager_factory.h"
#include "chrome/browser/password_manager/factories/profile_password_store_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "chrome/browser/webdata_services/web_data_service_factory.h"
#include "components/autofill/core/browser/data_manager/personal_data_manager.h"
#include "components/autofill/core/browser/data_manager/personal_data_manager_observer.h"
#include "components/autofill/core/browser/data_model/addresses/autofill_profile.h"
#include "components/autofill/core/browser/data_model/addresses/autofill_structured_address_component.h"
#include "components/autofill/core/browser/data_model/payments/credit_card.h"
#include "components/autofill/core/browser/field_types.h"
#include "components/autofill/core/browser/webdata/autofill_webdata_service.h"
#include "components/password_manager/core/browser/password_store/password_store_consumer.h"
#include "components/password_manager/core/browser/password_store/password_store_interface.h"
#include "components/password_manager/core/browser/password_store/stored_credential.h"
#include "content/public/browser/storage_partition.h"
#include "crypto/secure_util.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_options.h"
#include "net/cookies/cookie_util.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "url/gurl.h"

namespace open_engine {
namespace {
using Dict = CefRefPtr<CefDictionaryValue>;
using Records = CefRefPtr<CefListValue>;
using Stored = password_manager::StoredCredential;
using LoginResult = base::expected<std::vector<Stored>,
                                   password_manager::PasswordStoreBackendError>;
constexpr size_t kMaxSecretBytes = 64 * 1024;
constexpr size_t kMaxTextUnits = 32 * 1024;
constexpr size_t kMaxQueuedBatches = 4;

// The binary belongs to the bridge after the API call. Clear it under CEF's
// value lock, including rejected/duplicate batches, before dropping it.
void WipeBinary(CefRefPtr<CefBinaryValue> binary) {
  if (!binary) return;
  auto* impl = static_cast<CefBinaryValueImpl*>(binary.get());
  CefValueController::AutoLock lock(impl->controller());
  if (lock.verified()) {
    if (auto* value = impl->GetValueUnsafe(); value && value->is_blob())
      crypto::SecureZeroBuffer(value->GetBlob());
  }
}
std::string TakeSecret(Dict record, const char* key) {
  auto binary = record->GetBinary(key);
  if (!binary) return {};
  std::string out;
  if (binary->GetSize() <= kMaxSecretBytes) {
    out.resize(binary->GetSize());
    if (!out.empty()) binary->GetData(out.data(), out.size(), 0);
  }
  WipeBinary(binary);
  return out;
}
template <class Character>
void Wipe(std::basic_string<Character>& value) {
  crypto::SecureZeroBuffer(base::as_writable_byte_span(value));
  value.clear();
}
void WipeRecords(Records records) {
  for (size_t i = 0; records && i < records->GetSize(); ++i) {
    auto record = records->GetDictionary(i);
    if (!record) continue;
    for (const char* key : {"password", "note", "value", "number"})
      WipeBinary(record->GetBinary(key));
  }
}
bool KnownKey(int kind, const std::string& key) {
  switch (kind) {
    case 0:
      return key == "signon_realm" || key == "origin_url" || key == "action_url" ||
          key == "username_element" || key == "username" || key == "password_element" ||
          key == "password" || key == "scheme" || key == "blocked_by_user" ||
          key == "date_created" || key == "date_last_used" ||
          key == "date_password_modified" || key == "times_used" || key == "note";
    case 1:
      return key == "guid" || key == "fields" || key == "verification_statuses" ||
          key == "use_count" || key == "use_date" || key == "date_modified" ||
          key == "language_code";
    case 2:
      return key == "guid" || key == "name_on_card" || key == "expiration_month" ||
          key == "expiration_year" || key == "number" || key == "nickname" ||
          key == "use_count" || key == "use_date";
    case 3:
      return key == "name" || key == "value" || key == "domain" || key == "path" ||
          key == "creation" || key == "expiration" || key == "last_access" ||
          key == "last_update" || key == "secure" || key == "http_only" ||
          key == "same_site" || key == "priority" || key == "source_scheme" ||
          key == "source_port" || key == "top_frame_site_key" ||
          key == "has_cross_site_ancestor";
  }
  return false;
}
bool ValidRecord(Dict record, size_t& text_units, int kind, int depth = 0) {
  if (!record || depth > 1) return false;
  CefDictionaryValue::KeyList keys;
  record->GetKeys(keys);
  if (keys.size() > 128 || record->GetBool("_invalid")) return false;
  for (const auto& key : keys) {
    if (key.length() > 64 || (depth == 0 && !KnownKey(kind, key.ToString()))) return false;
    auto type = record->GetType(key);
    if (type == VTYPE_STRING) {
      const size_t size = record->GetString(key).length();
      if (size > kMaxTextUnits - text_units) return false;
      text_units += size;
    } else if (type == VTYPE_BINARY) {
      if (depth != 0 || (key != "password" && key != "note" &&
                        key != "value" && key != "number") ||
          record->GetBinary(key)->GetSize() > kMaxSecretBytes) return false;
    } else if (type == VTYPE_DICTIONARY) {
      if (depth != 0 || (key != "fields" && key != "verification_statuses") ||
          !ValidRecord(record->GetDictionary(key), text_units, kind, depth + 1)) return false;
    } else if (type == VTYPE_DOUBLE) {
      if (!std::isfinite(record->GetDouble(key))) return false;
    } else if (type != VTYPE_INT && type != VTYPE_BOOL) return false;
  }
  return true;
}
bool ValidBatch(Records records, int kind) {
  if (!records || records->GetSize() > 256) return false;
  for (size_t i = 0; i < records->GetSize(); ++i) {
    size_t units = 0;
    if (!ValidRecord(records->GetDictionary(i), units, kind)) return false;
  }
  // At most 256 KiB of copied text/secret data per record. The largest
  // character payload is 128 KiB of UTF-16 plus its terminator (a 64 KiB
  // ASCII secret); ordinary text needs at most 96 KiB of UTF-8. Four queued batches bound
  // bridge-owned payloads below 256 MiB, before upstream store copies.
  return true;
}
std::string Text(Dict record, const char* key) { return record->GetString(key).ToString(); }
bool FixtureHost(std::string_view host) {
  return host == "example.com" || host.ends_with(".example.com") ||
         host == "localhost" || host == "127.0.0.1";
}
bool FixtureURL(const std::string& value) {
  const GURL url(value);
  return url.is_valid() && FixtureHost(url.host());
}
bool FixtureCard(Dict record) {
  auto binary = record->GetBinary("number");
  if (!binary || binary->GetSize() < 15 || binary->GetSize() > 16) return false;
  std::array<char, 16> number{};
  const size_t size = binary->GetSize();
  bool allowed = false;
  if (binary->GetData(number.data(), size, 0) == size) {
    const std::string_view value(number.data(), size);
    allowed = value == "4111111111111111" || value == "5555555555554444" ||
              value == "378282246310005";
  }
  crypto::SecureZeroBuffer(base::as_writable_byte_span(number));
  return allowed;
}
bool FixtureBatch(Records records, int kind) {
  // Run in the browser process, before any store method sees this batch.
  // Do not consume secret binaries: accepted records still need them.
  for (size_t i = 0; i < records->GetSize(); ++i) {
    const auto record = records->GetDictionary(i);
    switch (kind) {
      case 0:
        if (!FixtureURL(Text(record, "signon_realm")) ||
            !FixtureURL(Text(record, "origin_url"))) return false;
        break;
      case 1:
        break;  // Addresses are allowed only with the fixture switch too.
      case 2:
        if (!FixtureCard(record)) return false;
        break;
      case 3: {
        std::string domain = base::ToLowerASCII(Text(record, "domain"));
        if (domain.starts_with('.')) domain.erase(0, 1);
        if (!FixtureHost(domain)) return false;
        break;
      }
      default:
        return false;
    }
  }
  return true;
}
base::Time Date(Dict record, const char* key) {
  return record->HasKey(key) ? base::Time::FromSecondsSinceUnixEpoch(record->GetDouble(key))
                             : base::Time();
}
void WipeLogins(LoginResult& result) {
  if (!result.has_value()) return;
  for (auto& form : *result) {
    form.password_value.clear();
    for (auto& note : form.notes) Wipe(note.value);
  }
}
using LoginKey = std::tuple<std::string, bool, std::u16string>;
LoginKey Key(const Stored& credential) {
  return {credential.signon_realm, credential.blocked_by_user,
          credential.blocked_by_user ? std::u16string() : credential.username_value};
}
bool SameCookieKey(const net::CanonicalCookie& a, const net::CanonicalCookie& b) {
  return a.Name() == b.Name() && a.Domain() == b.Domain() && a.Path() == b.Path() &&
         a.PartitionKey() == b.PartitionKey();
}
class ProfileData;
auto& Bridges() {
  static base::NoDestructor<std::map<CefRequestContext*, base::WeakPtr<ProfileData>>> bridges;
  return *bridges;
}

class ProfileData final : public CefOpenProfileData,
                          public password_manager::PasswordStoreConsumer,
                          public autofill::PersonalDataManagerObserver,
                          public ProfileObserver,
                          public autofill::AddressDataManager::Observer {
 public:
  explicit ProfileData(CefRefPtr<CefRequestContext> context) : context_(context) {}
  base::WeakPtr<ProfileData> GetWeakPtr() { return weak_.GetWeakPtr(); }
  void Start() {
    static_cast<CefRequestContextImpl*>(context_.get())
        ->ExecuteWhenBrowserContextInitialized(base::BindOnce(
            &ProfileData::Initialize, weak_.GetWeakPtr()));
  }
  void Close() override {
    CefRefPtr<ProfileData> alive(this);
    CloseImpl();
  }
  void CloseImpl() {
    CEF_REQUIRE_UIT();
    if (closed_) return;
    closed_ = true;
    weak_.InvalidateWeakPtrs();
    if (pdm_) {
      pdm_->RemoveObserver(this);
      pdm_->address_data_manager().RemoveObserver(this);
    }
    pdm_ = nullptr;
    if (profile_) profile_->RemoveObserver(this);
    profile_ = nullptr;
    if (context_) Bridges().erase(context_.get());
    context_ = nullptr;
    cookies_.clear();
    pending_guids_.clear();
    pending_login_keys_.clear();
    address_barrier_ = false;
    while (!jobs_.empty()) {
      auto job = std::move(jobs_.front()); jobs_.pop_front();
      WipeRecords(job.records);
      if (job.counts) job.counts->OnCounts(0, 0, 0, 0, 0);
      if (job.done) job.done->OnComplete(0, 0, job.records ? job.records->GetSize() : 0, 3);
    }
    read_logins_.Reset();
  }
  void OnProfileWillBeDestroyed(Profile*) override { Close(); }
  void GetCounts(CefRefPtr<CefOpenCountsCallback> callback) override {
    CEF_REQUIRE_UIT();
    if (!callback) return;
    if (closed_) { callback->OnCounts(0, 0, 0, 0, 0); return; }
    jobs_.push_back({-1, nullptr, nullptr, callback}); RunNext();
  }
  void ImportLogins(Records records, CefRefPtr<CefOpenImportCallback> done) override {
    Enqueue(0, records, done);
  }
  void ImportAddresses(Records records, CefRefPtr<CefOpenImportCallback> done) override {
    Enqueue(1, records, done);
  }
  void ImportCards(Records records, CefRefPtr<CefOpenImportCallback> done) override {
    Enqueue(2, records, done);
  }
  void ImportCookies(Records records, CefRefPtr<CefOpenImportCallback> done) override {
    Enqueue(3, records, done);
  }
  void OnPersonalDataChanged() override { RunNext(); }
  void OnAddressDataChanged() override {
    if (address_barrier_ && pdm_ &&
        !pdm_->address_data_manager().IsAwaitingPendingAddressChanges()) {
      address_barrier_ = false;
      WebDataBarrier(false);
    } else RunNext();
  }
  void OnGetPasswordStoreResultsOrErrorFrom(
      password_manager::PasswordStoreInterface*, LoginResult result) override {
    if (read_logins_) std::move(read_logins_).Run(std::move(result));
  }
 private:
  ~ProfileData() override { CloseImpl(); }
  struct Job {
    int kind;
    Records records;
    CefRefPtr<CefOpenImportCallback> done;
    CefRefPtr<CefOpenCountsCallback> counts;
  };
  void Initialize() {
    if (closed_ || !context_) return;
    profile_ = CefRequestContextImpl::GetProfile(context_);
    if (!profile_) { Close(); return; }
    profile_->AddObserver(this);
    if (!profile_->IsOffTheRecord()) {
      pdm_ = autofill::PersonalDataManagerFactory::GetForBrowserContext(profile_);
      if (pdm_) {
        pdm_->AddObserver(this);
        pdm_->address_data_manager().AddObserver(this);
      }
    }
    RunNext();
  }
  void Enqueue(int kind, Records records, CefRefPtr<CefOpenImportCallback> done) {
    CEF_REQUIRE_UIT();
    if (!done || closed_ || jobs_.size() >= kMaxQueuedBatches || !ValidBatch(records, kind)) {
      WipeRecords(records);
      if (done) done->OnComplete(0, 0, records ? records->GetSize() : 0, closed_ ? 3 : 0);
      return;
    }
    // Calls and input mutation belong to the UI thread. Take a bounded deep
    // snapshot before yielding to store reads: the caller must not change a
    // fixture-approved record into real data while that batch is waiting.
    auto snapshot = records->Copy();
    WipeRecords(records);
    if (!ValidBatch(snapshot, kind)) {
      WipeRecords(snapshot);
      done->OnComplete(0, 0, records->GetSize(), 0);
      return;
    }
    jobs_.push_back({kind, snapshot, done, nullptr}); RunNext();
  }
  void RunNext() {
    if (busy_ || closed_ || !profile_ || jobs_.empty()) return;
    if (pdm_ && !pdm_->IsDataLoaded()) return;
    busy_ = true;
    added_ = existing_ = failed_ = 0;
    if (jobs_.front().kind == -1) { ReadCounts(); return; }
    if (profile_->IsOffTheRecord()) {
      failed_ = jobs_.front().records->GetSize(); Finish(1); return;
    }
    auto* command = base::CommandLine::ForCurrentProcess();
    if (command->HasSwitch("use-mock-keychain") &&
        (!command->HasSwitch("open-allow-mock-keychain-secrets") ||
         !FixtureBatch(jobs_.front().records, jobs_.front().kind))) {
      failed_ = jobs_.front().records->GetSize(); Finish(2); return;
    }
    switch (jobs_.front().kind) {
      case 0: ImportPasswords(); break;
      case 1: ImportAddressData(); break;
      case 2: ImportCardData(); break;
      case 3: ImportCookieData(); break;
    }
  }
  void Finish(int error = 0) {
    if (closed_ || jobs_.empty()) return;
    CefRefPtr<ProfileData> alive(this);
    auto job = std::move(jobs_.front()); jobs_.pop_front();
    WipeRecords(job.records);
    busy_ = false;
    if (job.done) job.done->OnComplete(added_, existing_, failed_, error);
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&ProfileData::RunNext, weak_.GetWeakPtr()));
  }
  scoped_refptr<password_manager::PasswordStoreInterface> PasswordStore() {
    return ProfilePasswordStoreFactory::GetForProfile(profile_, ServiceAccessType::EXPLICIT_ACCESS);
  }
  network::mojom::CookieManager* Cookies() {
    return profile_->GetDefaultStoragePartition()->GetCookieManagerForBrowserProcess();
  }
  scoped_refptr<autofill::AutofillWebDataService> WebData() {
    return WebDataServiceFactory::GetAutofillWebDataForProfile(
        profile_, ServiceAccessType::EXPLICIT_ACCESS);
  }
  void ReadPasswords(base::OnceCallback<void(LoginResult)> callback) {
    auto store = PasswordStore();
    if (!store) { std::move(callback).Run(base::unexpected(
        password_manager::PasswordStoreBackendError(
            password_manager::PasswordStoreBackendErrorType::kUncategorized))); return; }
    read_logins_ = std::move(callback);
    store->GetAllLogins(weak_.GetWeakPtr());
  }
  void ReadCounts() {
    if (profile_->IsOffTheRecord()) { CompleteCounts(0, 0, 0, 0, 0); return; }
    ReadPasswords(base::BindOnce([](base::WeakPtr<ProfileData> self, LoginResult result) {
      if (!self) return;
      int logins = 0, blocked = 0;
      if (result.has_value()) for (const auto& form : *result)
        form.blocked_by_user ? ++blocked : ++logins;
      WipeLogins(result);
      const int cards = self->pdm_ ? self->pdm_->payments_data_manager().GetLocalCreditCards().size() : 0;
      const int addresses = self->pdm_ ? self->pdm_->address_data_manager().GetProfilesByRecordType(
          autofill::AutofillProfile::RecordType::kLocalOrSyncable).size() : 0;
      self->Cookies()->GetAllCookies(base::BindOnce(
          [](base::WeakPtr<ProfileData> self, int logins, int blocked, int cards,
              int addresses, const net::CookieList& cookies) {
            if (self) self->CompleteCounts(logins, blocked, cards, addresses, cookies.size());
          }, self, logins, blocked, cards, addresses));
    }, weak_.GetWeakPtr()));
  }
  void CompleteCounts(int logins, int blocked, int cards, int addresses, int cookies) {
    CefRefPtr<ProfileData> alive(this);
    auto callback = jobs_.front().counts;
    jobs_.front().counts = nullptr;
    Finish();
    callback->OnCounts(logins, blocked, cards, addresses, cookies);
  }
  void ImportPasswords() {
    ReadPasswords(base::BindOnce([](base::WeakPtr<ProfileData> self, LoginResult result) {
      if (!self) return;
      auto records = self->jobs_.front().records;
      if (!result.has_value()) { self->failed_ = records->GetSize(); self->Finish(); return; }
      std::set<LoginKey> keys;
      for (const auto& form : *result) keys.insert(Key(form));
      WipeLogins(result);
      self->pending_login_keys_.clear();
      std::vector<Stored> forms;
      for (size_t i = 0; i < records->GetSize(); ++i) {
        auto d = records->GetDictionary(i);
        if (!d) { ++self->failed_; continue; }
        Stored form;
        form.signon_realm = Text(d, "signon_realm");
        form.url = GURL(Text(d, "origin_url"));
        form.action = GURL(Text(d, "action_url"));
        form.username_element = d->GetString("username_element").ToString16();
        form.username_value = d->GetString("username").ToString16();
        form.password_element = d->GetString("password_element").ToString16();
        form.blocked_by_user = d->GetBool("blocked_by_user");
        int scheme = d->GetInt("scheme");
        auto password = TakeSecret(d, "password");
        auto note = TakeSecret(d, "note");
        // PasswordStore::AddLogins CHECKs this invariant for blocked sites.
        // A malformed caller record must never reach that fatal check.
        if (form.blocked_by_user) form.username_value.clear();
        const bool valid = scheme >= 0 && scheme <= 4 &&
            !form.signon_realm.empty() && form.url.is_valid() &&
            (form.blocked_by_user || !password.empty());
        if (!valid || !keys.insert(Key(form)).second) {
          valid ? ++self->existing_ : ++self->failed_;
          Wipe(password); Wipe(note);
          continue;
        }
        if (!form.blocked_by_user) {
          form.password_value = password_manager::PasswordString(base::UTF8ToUTF16(password));
          if (!note.empty()) {
            // Populate the store-owned note directly, with no UTF-16 copy.
            form.notes.emplace_back();
            form.notes.back().value = base::UTF8ToUTF16(note);
            form.notes.back().date_created = Date(d, "date_created");
          }
        }
        Wipe(password); Wipe(note);
        form.scheme = static_cast<password_manager::PasswordForm::Scheme>(scheme);
        form.date_created = Date(d, "date_created");
        form.date_last_used = Date(d, "date_last_used");
        form.date_password_modified = Date(d, "date_password_modified");
        form.times_used_in_html_form = std::max(0, d->GetInt("times_used"));
        self->pending_login_keys_.insert(Key(form));
        forms.push_back(std::move(form));
      }
      if (forms.empty()) { self->Finish(); return; }
      self->PasswordStore()->AddLogins(std::move(forms), base::BindOnce(
          &ProfileData::VerifyImportedPasswords, self));
    }, weak_.GetWeakPtr()));
  }
  void VerifyImportedPasswords() {
    // AddLogins' completion is the durability barrier, but does not carry
    // write errors. Read back keys before reporting successful additions.
    ReadPasswords(base::BindOnce([](base::WeakPtr<ProfileData> self, LoginResult result) {
      if (!self) return;
      std::set<LoginKey> stored;
      if (result.has_value()) for (const auto& form : *result) stored.insert(Key(form));
      WipeLogins(result);
      for (const auto& key : self->pending_login_keys_)
        stored.contains(key) ? ++self->added_ : ++self->failed_;
      self->pending_login_keys_.clear();
      self->Finish();
    }, weak_.GetWeakPtr()));
  }
  void ImportAddressData();
  void ImportCardData();
  void WebDataBarrier(bool cards);
  void ImportCookieData();
  void WriteNextCookie();

  CefRefPtr<CefRequestContext> context_;
  raw_ptr<Profile> profile_ = nullptr;
  raw_ptr<autofill::PersonalDataManager> pdm_ = nullptr;
  bool closed_ = false, busy_ = false, address_barrier_ = false;
  int added_ = 0, existing_ = 0, failed_ = 0;
  std::deque<Job> jobs_;
  base::OnceCallback<void(LoginResult)> read_logins_;
  net::CookieList cookies_;
  std::set<std::string> pending_guids_;
  std::set<LoginKey> pending_login_keys_;
  size_t cookie_index_ = 0;
  base::WeakPtrFactory<ProfileData> weak_{this};
  IMPLEMENT_REFCOUNTING(ProfileData);
};

void ProfileData::ImportAddressData() {
  auto records = jobs_.front().records;
  if (!pdm_ || !pdm_->address_data_manager().IsAutofillProfileEnabled() || !WebData()) {
    failed_ = records->GetSize(); Finish(); return;
  }
  auto& manager = pdm_->address_data_manager();
  std::vector<autofill::AutofillProfile> known;
  for (auto* profile : manager.GetProfilesByRecordType(
      autofill::AutofillProfile::RecordType::kLocalOrSyncable)) known.push_back(*profile);
  pending_guids_.clear();
  for (size_t i = 0; i < records->GetSize(); ++i) {
    auto d = records->GetDictionary(i);
    if (!d || !base::Uuid::ParseCaseInsensitive(Text(d, "guid")).is_valid()) {
      ++failed_; continue;
    }
    auto fields = d->GetDictionary("fields");
    auto statuses = d->GetDictionary("verification_statuses");
    if (!fields || !statuses) { ++failed_; continue; }
    autofill::AutofillProfile profile(Text(d, "guid"),
        autofill::AutofillProfile::RecordType::kLocalOrSyncable,
        autofill::AddressCountryCode(""));
    CefDictionaryValue::KeyList keys;
    fields->GetKeys(keys);
    bool valid = true;
    for (const auto& key : keys) {
      int number;
      if (!base::StringToInt(key.ToString(), &number)) { valid = false; break; }
      auto type = autofill::ToSafeFieldType(number);
      const int status = statuses->GetInt(key);
      if (!type || !autofill::AutofillProfile::kDatabaseStoredTypes.contains(*type) ||
          status < 0 || status > static_cast<int>(autofill::VerificationStatus::kMaxValue)) {
        valid = false; break;
      }
      profile.SetRawInfoWithVerificationStatus(*type, fields->GetString(key).ToString16(),
          static_cast<autofill::VerificationStatus>(status));
    }
    profile.set_language_code(Text(d, "language_code"));
    profile.usage_history().set_use_count(std::max(0, d->GetInt("use_count")));
    profile.usage_history().set_use_date(Date(d, "use_date"));
    profile.usage_history().set_modification_date(Date(d, "date_modified"));
    if (!valid || profile.IsEmpty("en-US")) { ++failed_; continue; }
    if (std::ranges::any_of(known, [&](const auto& old) {
          return old.guid() == profile.guid() || old.Compare(profile) == 0;
        })) { ++existing_; continue; }
    known.push_back(profile);
    pending_guids_.insert(profile.guid());
    manager.AddProfile(profile);
  }
  // ADM serializes its own queue. A read here could overtake later writes.
  // Wait for its all-pending-changes observer, THEN issue the service read.
  address_barrier_ = manager.IsAwaitingPendingAddressChanges();
  if (!address_barrier_) WebDataBarrier(false);
}

void ProfileData::ImportCardData() {
  auto records = jobs_.front().records;
  if (!pdm_ || !pdm_->payments_data_manager().IsAutofillPaymentMethodsEnabled() || !WebData()) {
    failed_ = records->GetSize(); Finish(); return;
  }
  auto& manager = pdm_->payments_data_manager();
  std::vector<autofill::CreditCard> known;
  for (auto* card : manager.GetLocalCreditCards()) known.push_back(*card);
  pending_guids_.clear();
  for (size_t i = 0; i < records->GetSize(); ++i) {
    auto d = records->GetDictionary(i);
    if (!d) { ++failed_; continue; }
    auto number = TakeSecret(d, "number");
    autofill::CreditCard card(Text(d, "guid"));
    card.SetNumber(base::UTF8ToUTF16(number));
    bool valid_digits = number.size() >= 12 && number.size() <= 19 &&
        std::ranges::all_of(number, [](char c) { return c >= '0' && c <= '9'; });
    Wipe(number);
    card.SetRawInfo(autofill::CREDIT_CARD_NAME_FULL, d->GetString("name_on_card").ToString16());
    card.SetExpirationMonth(d->GetInt("expiration_month"));
    card.SetExpirationYear(d->GetInt("expiration_year"));
    card.SetNickname(d->GetString("nickname").ToString16());
    card.usage_history().set_use_count(std::max(0, d->GetInt("use_count")));
    if (d->HasKey("use_date")) card.usage_history().set_use_date(Date(d, "use_date"));
    if (!valid_digits || !base::Uuid::ParseCaseInsensitive(card.guid()).is_valid() ||
        !card.HasValidCardNumber() || card.IsEmpty("en-US")) { ++failed_; continue; }
    if (std::ranges::any_of(known, [&](const auto& old) {
          return old.guid() == card.guid() || old.Compare(card) == 0;
        })) { ++existing_; continue; }
    known.push_back(card);
    pending_guids_.insert(card.guid());
    manager.AddCreditCard(card);
  }
  // PaymentsDataManager queues each write immediately on this service.
  WebDataBarrier(true);
}

void ProfileData::WebDataBarrier(bool cards) {
  auto service = WebData();
  auto callback = base::BindOnce(
      [](base::WeakPtr<ProfileData> self, bool cards, WebDataServiceBase::Handle,
          std::unique_ptr<WDTypedResult> result) {
        if (!self) return;
        std::set<std::string> stored;
        if (result && cards && result->GetType() == AUTOFILL_CREDITCARDS_RESULT) {
          for (const auto& card : static_cast<WDResult<std::vector<std::unique_ptr<autofill::CreditCard>>>*>(result.get())->GetValue())
            stored.insert(card->guid());
        } else if (result && !cards && result->GetType() == AUTOFILL_PROFILES_RESULT) {
          for (const auto& profile : static_cast<WDResult<std::vector<autofill::AutofillProfile>>*>(result.get())->GetValue())
            stored.insert(profile.guid());
        }
        for (const auto& guid : self->pending_guids_)
          stored.contains(guid) ? ++self->added_ : ++self->failed_;
        self->pending_guids_.clear();
        self->Finish();
      }, weak_.GetWeakPtr(), cards);
  if (!service) {
    failed_ += pending_guids_.size(); pending_guids_.clear(); Finish(); return;
  }
  if (cards) service->GetCreditCards(std::move(callback));
  else service->GetAutofillProfiles(std::move(callback));
}

void ProfileData::ImportCookieData() {
  Cookies()->GetAllCookies(base::BindOnce(
      [](base::WeakPtr<ProfileData> self, const net::CookieList& cookies) {
        if (!self) return;
        self->cookies_ = cookies;
        self->cookie_index_ = 0;
        self->WriteNextCookie();
      }, weak_.GetWeakPtr()));
}

void ProfileData::WriteNextCookie() {
  auto records = jobs_.front().records;
  while (cookie_index_ < records->GetSize()) {
    auto d = records->GetDictionary(cookie_index_++);
    if (!d) { ++failed_; continue; }
    auto value = TakeSecret(d, "value");
    auto partition = net::CookiePartitionKey::FromStorage(Text(d, "top_frame_site_key"),
        d->GetBool("has_cross_site_ancestor"));
    int same_site = d->GetInt("same_site"), priority = d->GetInt("priority"),
        source_scheme = d->GetInt("source_scheme");
    if (!partition.has_value() || same_site < -1 || same_site > 2 ||
        priority < 0 || priority > 2 || source_scheme < 0 || source_scheme > 2) {
      Wipe(value); ++failed_; continue;
    }
    auto cookie = net::CanonicalCookie::FromStorage(Text(d, "name"), value,
        Text(d, "domain"), Text(d, "path"), Date(d, "creation"),
        Date(d, "expiration"), Date(d, "last_access"), Date(d, "last_update"),
        d->GetBool("secure"), d->GetBool("http_only"),
        static_cast<net::CookieSameSite>(same_site),
        static_cast<net::CookiePriority>(priority), std::move(*partition),
        static_cast<net::CookieSourceScheme>(source_scheme), d->GetInt("source_port"),
        net::CookieSourceType::kOther, net::CanonicalCookieFromStorageCallSite::kCookieManager);
    Wipe(value);
    if (!cookie || cookie->IsExpired(base::Time::Now())) { ++failed_; continue; }
    if (std::ranges::any_of(cookies_, [&](const auto& old) { return SameCookieKey(old, *cookie); })) {
      ++existing_; continue;
    }
    const auto url = net::cookie_util::SimulatedCookieSource(*cookie,
        source_scheme == 2 || cookie->IsSecure() ? "https" : "http");
    // One write at a time also enforces existing-wins within a single batch.
    auto saved = *cookie;
    Cookies()->SetCanonicalCookie(*cookie, url, net::CookieOptions::MakeAllInclusive(),
        base::BindOnce([](base::WeakPtr<ProfileData> self, net::CanonicalCookie cookie,
                         net::CookieAccessResult result) {
          if (!self) return;
          if (result.status.IsInclude()) { ++self->added_; self->cookies_.push_back(cookie); }
          else ++self->failed_;
          self->WriteNextCookie();
        }, weak_.GetWeakPtr(), std::move(saved)));
    return;
  }
  cookies_.clear();
  Cookies()->FlushCookieStore(base::BindOnce(&ProfileData::Finish, weak_.GetWeakPtr(), 0));
}
}  // namespace
}  // namespace open_engine

CefRefPtr<CefOpenProfileData> CefOpenProfileData::GetForContext(
    CefRefPtr<CefRequestContext> context) {
  CEF_REQUIRE_UIT_RETURN(nullptr);
  if (!context) return nullptr;
  auto& bridge = open_engine::Bridges()[context.get()];
  if (bridge) return bridge.get();
  CefRefPtr<open_engine::ProfileData> result = new open_engine::ProfileData(context);
  bridge = result->GetWeakPtr();
  result->Start();
  return result;
}
