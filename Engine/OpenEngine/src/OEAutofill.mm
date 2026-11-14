// Copyright 2026 The Open Authors. BSD-style license in LICENSE.
#import "OEInternal.h"
#import <objc/runtime.h>
#include <cstring>
#include <climits>
#include <cmath>

#include "include/cef_open_autofill.h"
#include "include/cef_command_line.h"

namespace {
BOOL gAutofillActive = NO;
BOOL AutofillAvailable() { return gAutofillActive && OEEngine.shared.running; }
OEWebContent* ContentFor(CefRefPtr<CefBrowser> browser) {
  if (!browser) return nil;
  for (OEWebContent* content in OEEngine.shared.allWebContents) {
    auto page = content.oe_browser;
    if (page && page->IsSame(browser)) return content;
  }
  return nil;
}
NSMapTable<NSNumber*, OESavePrompt*>* Prompts() {
  static NSMapTable<NSNumber*, OESavePrompt*>* prompts =
      [NSMapTable strongToWeakObjectsMapTable];
  return prompts;
}
BOOL HasBrowserSwitch(NSString* name) {
  if (OEEngine.shared.running) {
    auto command = CefCommandLine::GetGlobalCommandLine();
    return command && command->HasSwitch(OECef(name));
  }
  NSString* flag = [@"--" stringByAppendingString:name];
  NSString* prefix = [flag stringByAppendingString:@"="];
  NSArray<NSString*>* switches = [NSProcessInfo.processInfo.arguments
      arrayByAddingObjectsFromArray:OEEngine.shared.configuration.additionalSwitches ?: @[]];
  for (NSString* value in switches)
    if ([value isEqualToString:flag] || [value hasPrefix:prefix]) return YES;
  return NO;
}
BOOL MockPromptsAllowed() {
  return !OEEngine.shared.usesMockKeychain ||
      HasBrowserSwitch(@"open-allow-mock-keychain-secrets");
}
}

@interface OESavePrompt ()
- (instancetype)initOEWithPrompt:(CefRefPtr<CefSavePrompt>)prompt
                      webContent:(OEWebContent*)content;
- (void)oe_withdraw;
- (BOOL)oe_matchesPrompt:(CefRefPtr<CefSavePrompt>)prompt;
@end
@implementation OESavePrompt {
  CefRefPtr<CefSavePrompt> _prompt;
  BOOL _answered;
}
- (instancetype)initOEWithPrompt:(CefRefPtr<CefSavePrompt>)prompt
                      webContent:(OEWebContent*)content {
  if ((self = [super init])) {
    _prompt = prompt;
    _kind = (OESavePromptKind)prompt->GetKind();
    _origin = OEString(prompt->GetOrigin());
    _displayHost = OEString(prompt->GetDisplayHost());
    _username = _kind <= OESavePromptKindPasswordUpdate
        ? OEString(prompt->GetUsername()) : nil;
    _cardLabel = _kind == OESavePromptKindCard ? OEString(prompt->GetCardLabel()) : nil;
    _addressLabel = _kind >= OESavePromptKindAddress ? OEString(prompt->GetAddressLabel()) : nil;
    _isUserInitiated = prompt->IsUserInitiated();
    _webContent = content;
  }
  return self;
}
- (void)dealloc { if (_prompt) _prompt->Answer((int)OESavePromptAnswerIgnored); }
- (BOOL)isAnswered { return _answered || !_prompt || _prompt->IsAnswered(); }
- (BOOL)offersNeverForSite { return _kind == OESavePromptKindPassword; }
- (void)answer:(OESavePromptAnswer)answer {
  auto prompt = _prompt;
  _prompt = nullptr;
  _answered = YES;
  if (prompt) prompt->Answer((int)answer);
}
- (void)oe_withdraw { _answered = YES; _prompt = nullptr; }
- (BOOL)oe_matchesPrompt:(CefRefPtr<CefSavePrompt>)prompt {
  return _prompt && _prompt->IsSame(prompt);
}
@end

class OEAutofillHandler final : public CefOpenAutofillHandler {
 public:
  bool IsOpenBrowser(CefRefPtr<CefBrowser> browser) override {
    return ContentFor(browser) != nil;
  }
  void OnShowSavePrompt(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefSavePrompt> prompt) override {
    OEWebContent* content = ContentFor(browser);
    // Defence at both sides of the shared-library boundary. The switch
    // permits fixture prompts; imports validate every record separately.
    if (!content || content.context.ephemeral ||
        (prompt->GetKind() <= 2 && !MockPromptsAllowed())) {
      prompt->Answer((int)OESavePromptAnswerIgnored);
      return;
    }
    OESavePrompt* offer = [[OESavePrompt alloc] initOEWithPrompt:prompt webContent:content];
    [Prompts() setObject:offer forKey:@(browser->GetIdentifier())];
    id<OEWebContentDelegate> delegate = content.delegate;
    if ([delegate respondsToSelector:@selector(webContent:showSavePrompt:)])
      [delegate webContent:content showSavePrompt:offer];
    // The shell keeps queued offers. Otherwise dealloc answers Ignored.
  }
  void OnWithdrawSavePrompt(CefRefPtr<CefBrowser> browser,
                            CefRefPtr<CefSavePrompt> prompt) override {
    NSNumber* key = @(browser->GetIdentifier());
    OESavePrompt* offer = [Prompts() objectForKey:key];
    if (!offer || ![offer oe_matchesPrompt:prompt]) return;
    [offer oe_withdraw];
    [Prompts() removeObjectForKey:key];
    OEWebContent* content = offer.webContent;
    id<OEWebContentDelegate> delegate = content.delegate;
    if (content && [delegate respondsToSelector:@selector(webContent:withdrawSavePrompt:)])
      [delegate webContent:content withdrawSavePrompt:offer];
  }
  void OnOpenAutofillPage(CefRefPtr<CefBrowser> browser, int page) override {
    OEWebContent* content = ContentFor(browser);
    id<OEWebContentDelegate> delegate = content.delegate;
    if (content && [delegate respondsToSelector:@selector(webContent:openAutofillPage:)])
      [delegate webContent:content openAutofillPage:(OEAutofillPage)page];
  }
  void OnPasswordSaveKeychainError(CefRefPtr<CefBrowser> browser) override {
    OEWebContent* content = ContentFor(browser);
    id<OEWebContentDelegate> delegate = content.delegate;
    if (content && [delegate respondsToSelector:
            @selector(webContentDidFailToSavePasswordForKeychainError:)])
      [delegate webContentDidFailToSavePasswordForKeychainError:content];
  }
 private:
  IMPLEMENT_REFCOUNTING(OEAutofillHandler);
};
void OEInstallAutofillHandler() {
  gAutofillActive = YES;
  CefSetOpenAutofillHandler(new OEAutofillHandler());
}
void OERemoveAutofillHandler() {
  // Close callbacks may call the API again before OEEngine clears running.
  gAutofillActive = NO;
  // Shell sheets may outlive shutdown. Release every CEF prompt before the
  // library loader goes away, including offers already answered by CEF.
  for (OESavePrompt* offer in Prompts().objectEnumerator) [offer oe_withdraw];
  CefSetOpenAutofillHandler(nullptr);
  [Prompts() removeAllObjects];
}

@interface OECredentialCounts ()
- (instancetype)initOEWithLogins:(int)logins blocked:(int)blocked cards:(int)cards
                       addresses:(int)addresses cookies:(int)cookies;
@end
@implementation OECredentialCounts
- (instancetype)initOEWithLogins:(int)logins blocked:(int)blocked cards:(int)cards
                       addresses:(int)addresses cookies:(int)cookies {
  if ((self = [super init])) {
    _logins = logins; _blockedSites = blocked; _cards = cards;
    _addresses = addresses; _cookies = cookies;
  }
  return self;
}
@end
@interface OEImportResult ()
- (instancetype)initOEWithAdded:(int)added existing:(int)existing failed:(int)failed;
@end
@implementation OEImportResult
- (instancetype)initOEWithAdded:(int)added existing:(int)existing failed:(int)failed {
  if ((self = [super init])) { _added = added; _existing = existing; _failed = failed; }
  return self;
}
@end

@interface OEAutofillContextState : NSObject {
 @public CefRefPtr<CefOpenProfileData> data;
}
@end
@implementation OEAutofillContextState
@end
namespace {
char kAutofillContextState;
OEAutofillContextState* ContextState(OEBrowserContext* context, BOOL create) {
  OEAutofillContextState* state = objc_getAssociatedObject(context, &kAutofillContextState);
  if (!state && create) {
    state = [OEAutofillContextState new];
    state->data = CefOpenProfileData::GetForContext(context.oe_requestContext);
    objc_setAssociatedObject(context, &kAutofillContextState, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return state;
}
BOOL Preference(OEBrowserContext* context, const char* name) {
  if (context.ephemeral) return NO;
  if (!AutofillAvailable() || !context.oe_isReady) return YES;
  auto value = context.oe_requestContext->GetPreference(name);
  return value && value->GetBool();
}
void SetPreference(OEBrowserContext* context, const char* name, BOOL enabled) {
  if (context.ephemeral || !AutofillAvailable()) return;
  std::string key(name);
  [context oe_whenReady:^{
    // oe_whenReady also runs this when the context closed (and then
    // oe_requestContext is null), not only when it became ready.
    if (!AutofillAvailable() || !context.oe_isReady) return;
    auto request = context.oe_requestContext;
    if (!request || !request->CanSetPreference(key)) return;
    auto value = CefValue::Create(); value->SetBool(enabled);
    CefString error;
    request->SetPreference(key, value, error);
  }];
}
BOOL CanEnable(OEBrowserContext* context, const char* name) {
  return AutofillAvailable() && !context.ephemeral && MockPromptsAllowed() && context.oe_isReady &&
      context.oe_requestContext->CanSetPreference(name);
}
}
class OECountsCallback final : public CefOpenCountsCallback {
 public:
  explicit OECountsCallback(void (^done)(OECredentialCounts*)) : done_([done copy]) {}
  ~OECountsCallback() override {
    if (auto done = done_) dispatch_async(dispatch_get_main_queue(), ^{
      done([[OECredentialCounts alloc] initOEWithLogins:0 blocked:0 cards:0 addresses:0 cookies:0]);
    });
  }
  void OnCounts(int logins, int blocked, int cards, int addresses, int cookies) override {
    auto done = done_; done_ = nil;
    if (done) done([[OECredentialCounts alloc] initOEWithLogins:logins blocked:blocked
        cards:cards addresses:addresses cookies:cookies]);
  }
 private:
  void (^done_)(OECredentialCounts*);
  IMPLEMENT_REFCOUNTING(OECountsCallback);
};
@implementation OEBrowserContext (Autofill)
- (void)oe_closeAutofill {
  auto* state = ContextState(self, NO);
  if (state && state->data) { state->data->Close(); state->data = nullptr; }
}
- (BOOL)passwordSavingEnabled { return Preference(self, "credentials_enable_service"); }
- (BOOL)canEnablePasswordSaving { return CanEnable(self, "credentials_enable_service"); }
- (void)setPasswordSavingEnabled:(BOOL)enabled {
  if (!enabled || self.canEnablePasswordSaving) SetPreference(self, "credentials_enable_service", enabled);
}
- (BOOL)creditCardsSavingEnabled { return Preference(self, "autofill.credit_card_enabled"); }
- (BOOL)canEnableCreditCardsSaving { return CanEnable(self, "autofill.credit_card_enabled"); }
- (void)setCreditCardsSavingEnabled:(BOOL)enabled {
  if (!enabled || self.canEnableCreditCardsSaving) SetPreference(self, "autofill.credit_card_enabled", enabled);
}
- (BOOL)creditCardReauthenticationEnabled { return Preference(self, "autofill.payment_methods_mandatory_reauth"); }
- (void)setCreditCardReauthenticationEnabled:(BOOL)enabled {
  SetPreference(self, "autofill.payment_methods_mandatory_reauth", enabled);
}
- (BOOL)addressesSavingEnabled { return Preference(self, "autofill.profile_enabled"); }
- (void)setAddressesSavingEnabled:(BOOL)enabled { SetPreference(self, "autofill.profile_enabled", enabled); }
- (void)fetchCredentialCountsWithCompletion:(void (^)(OECredentialCounts*))completion {
  // Private contexts have no saved data. Neither they nor a stopped engine
  // need a CEF data bridge that could outlive profile/library teardown.
  if (self.ephemeral || !AutofillAvailable()) {
    completion([[OECredentialCounts alloc] initOEWithLogins:0 blocked:0 cards:0 addresses:0 cookies:0]);
    return;
  }
  auto state = ContextState(self, YES);
  if (state->data) state->data->GetCounts(new OECountsCallback(completion));
  else completion([[OECredentialCounts alloc] initOEWithLogins:0 blocked:0 cards:0 addresses:0 cookies:0]);
}
+ (NSURL*)URLForAutofillPage:(OEAutofillPage)page {
  switch (page) {
    case OEAutofillPagePaymentMethods: return [NSURL URLWithString:@"chrome://settings/payments"];
    case OEAutofillPageAddresses: return [NSURL URLWithString:@"chrome://settings/addresses"];
    default: return [NSURL URLWithString:@"chrome://password-manager/passwords"];
  }
}
@end
@implementation OEEngine (Autofill)
- (BOOL)supportsSecretsImport { return AutofillAvailable(); }
- (BOOL)usesMockKeychain {
  return self.configuration.useMockKeychain || HasBrowserSwitch(@"use-mock-keychain");
}
@end

// Import records own Foundation strings until a live engine accepts a batch.
// They can be created before startup and released after engine shutdown.
@protocol OEImportRecord <NSObject>
- (CefRefPtr<CefDictionaryValue>)oe_takeRecordIncludingSecrets:(BOOL)include;
@end
namespace {
CefRefPtr<CefDictionaryValue> CefRecord(NSDictionary<NSString*, id>* record) {
  auto result = CefDictionaryValue::Create();
  for (NSString* key in record) {
    id value = record[key];
    if ([value isKindOfClass:NSString.class]) {
      result->SetString(OECef(key), OECef(value));
    } else if ([value isKindOfClass:NSDictionary.class]) {
      result->SetDictionary(OECef(key), CefRecord(value));
    } else if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
      result->SetBool(OECef(key), [value boolValue]);
    } else if (strcmp([value objCType], @encode(double)) == 0) {
      result->SetDouble(OECef(key), [value doubleValue]);
    } else {
      result->SetInt(OECef(key), [value intValue]);
    }
  }
  return result;
}
constexpr NSUInteger kMaxImportTextUnits = 32 * 1024;
constexpr NSUInteger kMaxImportSecretBytes = 64 * 1024;
BOOL ImportCountValid(NSInteger value) { return value >= 0 && value <= INT_MAX; }
BOOL RecordStringsBounded(NSArray<NSString*>* strings) {
  NSUInteger total = 0;
  for (NSString* string in strings) {
    if (string.length > kMaxImportTextUnits - total) return NO;
    total += string.length;
  }
  return YES;
}
BOOL AddressFieldsBounded(NSDictionary<NSNumber*, NSString*>* fields,
                          NSDictionary<NSNumber*, NSNumber*>* statuses,
                          NSString* guid, NSString* language) {
  if (fields.count > 128 || statuses.count > 128) return NO;
  NSUInteger total = guid.length + language.length;
  if (total > kMaxImportTextUnits) return NO;
  for (NSNumber* key in fields) {
    if (!std::isfinite(key.doubleValue) || key.doubleValue < 0 ||
        key.doubleValue > INT_MAX || key.doubleValue != key.intValue) return NO;
    if (fields[key].length > kMaxImportTextUnits - total) return NO;
    total += fields[key].length;
  }
  for (NSNumber* key in statuses) {
    NSNumber* status = statuses[key];
    if (!fields[key] || !std::isfinite(status.doubleValue) ||
        status.doubleValue < 0 || status.doubleValue > 5 ||
        status.doubleValue != status.intValue) return NO;
  }
  return YES;
}
void RecordDate(NSMutableDictionary<NSString*, id>* record, NSString* key, NSDate* date) {
  if (date) record[key] = @(date.timeIntervalSince1970);
}
}
#define OE_RECORD_IVARS \
  NSMutableDictionary<NSString*, id>* _record; \
  NSDictionary<NSString*, NSMutableData*>* _secrets;
#define OE_RECORD_METHODS \
- (CefRefPtr<CefDictionaryValue>)oe_takeRecordIncludingSecrets:(BOOL)include { \
  auto result = include ? CefRecord(_record) : nullptr; \
  include = include && ![_record[@"_invalid"] boolValue]; \
  for (NSString* key in _secrets) { \
    NSMutableData* bytes = _secrets[key]; \
    if (include && bytes.length) result->SetBinary(OECef(key), \
        CefBinaryValue::Create(bytes.bytes, bytes.length)); \
    [bytes resetBytesInRange:NSMakeRange(0, bytes.length)]; \
  } \
  _secrets = @{}; \
  return result; \
} \
- (void)dealloc { \
  for (NSMutableData* bytes in _secrets.allValues) \
    [bytes resetBytesInRange:NSMakeRange(0, bytes.length)]; \
}
@interface OEImportedLogin () <OEImportRecord> @end
@implementation OEImportedLogin { OE_RECORD_IVARS }
- (instancetype)initWithSignonRealm:(NSString*)realm originURL:(NSString*)origin
    actionURL:(NSString*)action usernameElement:(NSString*)usernameElement
    username:(NSString*)username passwordElement:(NSString*)passwordElement
    password:(NSMutableData*)password scheme:(NSInteger)scheme blockedByUser:(BOOL)blocked
    dateCreated:(NSDate*)created dateLastUsed:(NSDate*)used datePasswordModified:(NSDate*)modified
    timesUsed:(NSInteger)timesUsed note:(NSMutableData*)note {
  if ((self = [super init])) {
    _record = [NSMutableDictionary dictionary];
    _secrets = note ? @{@"password": password, @"note": note} : @{@"password": password};
    if (!RecordStringsBounded(@[realm, origin, action ?: @"", usernameElement, username, passwordElement]) ||
        password.length > kMaxImportSecretBytes || note.length > kMaxImportSecretBytes ||
        scheme < 0 || scheme > 4 || !ImportCountValid(timesUsed)) {
      _record[@"_invalid"] = @YES; return self;
    }
    _record[@"signon_realm"] = [realm ?: @"" copy];
    _record[@"origin_url"] = [origin ?: @"" copy];
    _record[@"action_url"] = [action ?: @"" copy];
    _record[@"username_element"] = [usernameElement ?: @"" copy];
    _record[@"username"] = [username ?: @"" copy];
    _record[@"password_element"] = [passwordElement ?: @"" copy];
    _record[@"scheme"] = @(scheme);
    _record[@"blocked_by_user"] = @(blocked);
    _record[@"times_used"] = @(timesUsed);
    RecordDate(_record, @"date_created", created); RecordDate(_record, @"date_last_used", used);
    RecordDate(_record, @"date_password_modified", modified);
  }
  return self;
}
OE_RECORD_METHODS
@end
@interface OEImportedCookie () <OEImportRecord> @end
@implementation OEImportedCookie { OE_RECORD_IVARS }
- (instancetype)initWithName:(NSString*)name value:(NSMutableData*)value domain:(NSString*)domain
    path:(NSString*)path creation:(NSDate*)creation expiration:(NSDate*)expiration
    lastAccess:(NSDate*)lastAccess lastUpdate:(NSDate*)lastUpdate secure:(BOOL)secure
    httpOnly:(BOOL)httpOnly sameSite:(NSInteger)sameSite priority:(NSInteger)priority
    sourceScheme:(NSInteger)sourceScheme sourcePort:(NSInteger)sourcePort
    topFrameSiteKey:(NSString*)partition hasCrossSiteAncestor:(BOOL)ancestor {
  if ((self = [super init])) {
    _record = [NSMutableDictionary dictionary];
    _secrets = @{@"value": value};
    if (!RecordStringsBounded(@[name, domain, path, partition ?: @""]) ||
        value.length > kMaxImportSecretBytes || sameSite < -1 || sameSite > 2 ||
        priority < 0 || priority > 2 || sourceScheme < 0 || sourceScheme > 2 ||
        sourcePort < -1 || sourcePort > 65535) {
      _record[@"_invalid"] = @YES; return self;
    }
    _record[@"name"] = [name ?: @"" copy]; _record[@"domain"] = [domain ?: @"" copy];
    _record[@"path"] = [path ?: @"" copy]; _record[@"top_frame_site_key"] = [partition ?: @"" copy];
    _record[@"secure"] = @(secure); _record[@"http_only"] = @(httpOnly);
    _record[@"has_cross_site_ancestor"] = @(ancestor);
    _record[@"same_site"] = @(sameSite); _record[@"priority"] = @(priority);
    _record[@"source_scheme"] = @(sourceScheme); _record[@"source_port"] = @(sourcePort);
    RecordDate(_record, @"creation", creation); RecordDate(_record, @"expiration", expiration);
    RecordDate(_record, @"last_access", lastAccess); RecordDate(_record, @"last_update", lastUpdate);
  }
  return self;
}
OE_RECORD_METHODS
@end
@interface OEImportedAddress () <OEImportRecord> @end
@implementation OEImportedAddress { OE_RECORD_IVARS }
- (instancetype)initWithGUID:(NSString*)guid fields:(NSDictionary<NSNumber*, NSString*>*)fields
    verificationStatuses:(NSDictionary<NSNumber*, NSNumber*>*)statuses useCount:(NSInteger)useCount
    useDate:(NSDate*)useDate dateModified:(NSDate*)dateModified languageCode:(NSString*)languageCode {
  if ((self = [super init])) {
    _record = [NSMutableDictionary dictionary];
    _secrets = @{};
    if (!AddressFieldsBounded(fields, statuses, guid, languageCode ?: @"") ||
        !ImportCountValid(useCount)) {
      _record[@"_invalid"] = @YES; return self;
    }
    _record[@"guid"] = [guid ?: @"" copy]; _record[@"language_code"] = [languageCode ?: @"" copy];
    _record[@"use_count"] = @(useCount);
    RecordDate(_record, @"use_date", useDate); RecordDate(_record, @"date_modified", dateModified);
    NSMutableDictionary* values = [NSMutableDictionary dictionary];
    NSMutableDictionary* verification = [NSMutableDictionary dictionary];
    for (NSNumber* key in fields) values[key.stringValue] = [fields[key] copy];
    for (NSNumber* key in statuses) verification[key.stringValue] = [statuses[key] copy];
    _record[@"fields"] = values; _record[@"verification_statuses"] = verification;
  }
  return self;
}
OE_RECORD_METHODS
@end
@interface OEImportedCard () <OEImportRecord> @end
@implementation OEImportedCard { OE_RECORD_IVARS }
- (instancetype)initWithGUID:(NSString*)guid nameOnCard:(NSString*)name
    expirationMonth:(NSInteger)month expirationYear:(NSInteger)year number:(NSMutableData*)number
    nickname:(NSString*)nickname useCount:(NSInteger)useCount useDate:(NSDate*)useDate {
  if ((self = [super init])) {
    _record = [NSMutableDictionary dictionary];
    _secrets = @{@"number": number};
    if (!RecordStringsBounded(@[guid, name, nickname ?: @""]) ||
        number.length > kMaxImportSecretBytes || month < 0 || month > 12 ||
        year < 0 || year > 9999 || !ImportCountValid(useCount)) {
      _record[@"_invalid"] = @YES; return self;
    }
    _record[@"guid"] = [guid ?: @"" copy]; _record[@"name_on_card"] = [name ?: @"" copy];
    _record[@"nickname"] = [nickname ?: @"" copy];
    _record[@"expiration_month"] = @(month); _record[@"expiration_year"] = @(year);
    _record[@"use_count"] = @(useCount); RecordDate(_record, @"use_date", useDate);
  }
  return self;
}
OE_RECORD_METHODS
@end
#undef OE_RECORD_IVARS
#undef OE_RECORD_METHODS

class OEImportCallback final : public CefOpenImportCallback {
 public:
  explicit OEImportCallback(void (^done)(OEImportResult*, NSError*)) : done_([done copy]) {}
  ~OEImportCallback() override {
    if (auto done = done_) dispatch_async(dispatch_get_main_queue(), ^{
      done(nil, [NSError errorWithDomain:OEErrorDomain code:OEErrorWebContentClosed userInfo:nil]);
    });
  }
  void OnComplete(int added, int existing, int failed, int error) override {
    auto done = done_; done_ = nil;
    if (!done) return;
    if (error) {
      OEErrorCode code = error == 1 ? OEErrorEphemeralContext :
          error == 2 ? OEErrorMockKeychain : OEErrorWebContentClosed;
      done(nil, [NSError errorWithDomain:OEErrorDomain code:code userInfo:nil]);
    } else {
      done([[OEImportResult alloc] initOEWithAdded:added existing:existing failed:failed], nil);
    }
  }
 private:
  void (^done_)(OEImportResult*, NSError*);
  IMPLEMENT_REFCOUNTING(OEImportCallback);
};
namespace {
void Import(OEBrowserContext* context, NSArray<id<OEImportRecord>>* records, int kind,
            void (^completion)(OEImportResult*, NSError*)) {
  // Refusal clears every supplied source, without making binary copies.
  OEErrorCode error = context.ephemeral ? OEErrorEphemeralContext :
      OEEngine.shared.usesMockKeychain && !HasBrowserSwitch(@"open-allow-mock-keychain-secrets")
        ? OEErrorMockKeychain : records.count > 256 || !AutofillAvailable()
        ? OEErrorUnsupported : (OEErrorCode)0;
  auto state = !error ? ContextState(context, YES) : nil;
  if (!error && (!state || !state->data)) error = OEErrorUnsupported;
  CefRefPtr<CefListValue> list;
  if (!error) list = CefListValue::Create();
  for (id<OEImportRecord> record in records) {
    auto value = [record oe_takeRecordIncludingSecrets:!error];
    if (list) list->SetDictionary(list->GetSize(), value);
  }
  if (error) {
    completion(nil, [NSError errorWithDomain:OEErrorDomain code:error userInfo:nil]);
    return;
  }
  auto callback = CefRefPtr<CefOpenImportCallback>(new OEImportCallback(completion));
  switch (kind) {
    case 0: state->data->ImportLogins(list, callback); break;
    case 1: state->data->ImportAddresses(list, callback); break;
    case 2: state->data->ImportCards(list, callback); break;
    case 3: state->data->ImportCookies(list, callback); break;
  }
}
}
@implementation OEBrowserContext (SecretsImport)
- (void)importLogins:(NSArray<OEImportedLogin*>*)records completion:(void (^)(OEImportResult*, NSError*))done {
  Import(self, (NSArray*)records, 0, done);
}
- (void)importAddresses:(NSArray<OEImportedAddress*>*)records completion:(void (^)(OEImportResult*, NSError*))done {
  Import(self, (NSArray*)records, 1, done);
}
- (void)importCards:(NSArray<OEImportedCard*>*)records completion:(void (^)(OEImportResult*, NSError*))done {
  Import(self, (NSArray*)records, 2, done);
}
- (void)importCookies:(NSArray<OEImportedCookie*>*)records completion:(void (^)(OEImportResult*, NSError*))done {
  Import(self, (NSArray*)records, 3, done);
}
@end
