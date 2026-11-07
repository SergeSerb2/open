// Copyright 2026 The Open Authors. BSD-style license in LICENSE.
#pragma once
#import <OpenEngine/OEDefines.h>
#import <OpenEngine/OEEngine.h>
#import <OpenEngine/OEBrowserContext.h>

NS_ASSUME_NONNULL_BEGIN
@class OEWebContent;

typedef NS_ENUM(NSInteger, OESavePromptKind) {
  OESavePromptKindPassword = 0,
  OESavePromptKindPasswordUpdate,
  OESavePromptKindCard,
  OESavePromptKindAddress,
  OESavePromptKindAddressUpdate,
} NS_SWIFT_NAME(OESavePrompt.Kind);

typedef NS_ENUM(NSInteger, OESavePromptAnswer) {
  OESavePromptAnswerSave = 0,        // "Save"
  OESavePromptAnswerNeverForSite,    // "Never on this site" (password save only)
  OESavePromptAnswerDismiss,         // "No", "Not Now", "No Thanks", Esc
  OESavePromptAnswerIgnored,         // closed without a choice
} NS_SWIFT_NAME(OESavePrompt.Answer);

NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OESavePrompt : NSObject
@property(nonatomic, readonly) OESavePromptKind kind;
@property(nonatomic, readonly, copy) NSString* origin;        // "https://accounts.example.com"
@property(nonatomic, readonly, copy) NSString* displayHost;   // "accounts.example.com"
@property(nonatomic, readonly, copy, nullable) NSString* username;      // password kinds; not shown in v1 UI
@property(nonatomic, readonly, copy, nullable) NSString* cardLabel;     // "Visa •••• 4242"
@property(nonatomic, readonly, copy, nullable) NSString* addressLabel;  // one line
@property(nonatomic, readonly) BOOL offersNeverForSite;       // YES only for OESavePromptKindPassword
@property(nonatomic, readonly) BOOL isUserInitiated;
@property(nonatomic, readonly) BOOL isAnswered;
@property(nonatomic, readonly, weak, nullable) OEWebContent* webContent;
/// The first call wins; later calls do nothing. A prompt that is released
/// unanswered answers OESavePromptAnswerIgnored.
- (void)answer:(OESavePromptAnswer)answer;
@end

typedef NS_ENUM(NSInteger, OEAutofillPage) {
  OEAutofillPagePasswords = 0,      // chrome://password-manager/passwords
  OEAutofillPagePaymentMethods,     // chrome://settings/payments
  OEAutofillPageAddresses,          // chrome://settings/addresses
} NS_SWIFT_NAME(OEAutofillPage);

NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OECredentialCounts : NSObject
@property(nonatomic, readonly) NSInteger logins;        // saved passwords, blocked sites excluded
@property(nonatomic, readonly) NSInteger blockedSites;  // "Never on this site" entries
@property(nonatomic, readonly) NSInteger cards;         // local cards
@property(nonatomic, readonly) NSInteger addresses;     // local addresses
@property(nonatomic, readonly) NSInteger cookies;
@end

@interface OEBrowserContext (Autofill)
@property(nonatomic) BOOL passwordSavingEnabled;           // credentials_enable_service
@property(nonatomic, readonly) BOOL canEnablePasswordSaving; // NO: ephemeral context, mock key (§7.1), or policy
@property(nonatomic) BOOL creditCardsSavingEnabled;        // autofill.credit_card_enabled
@property(nonatomic, readonly) BOOL canEnableCreditCardsSaving;
@property(nonatomic) BOOL creditCardReauthenticationEnabled; // autofill.payment_methods_mandatory_reauth
@property(nonatomic) BOOL addressesSavingEnabled;          // autofill.profile_enabled
- (void)fetchCredentialCountsWithCompletion:(void (^)(OECredentialCounts* counts))completion
    NS_SWIFT_NAME(fetchCredentialCounts(completion:));     // imports as async
+ (NSURL*)URLForAutofillPage:(OEAutofillPage)page;
@end

/// Records copy strings. Secret bytes come in NSMutableData; the engine
/// copies them and overwrites the NSMutableData with zeros before it
/// returns from the import call. The caller zeroes its own buffers.
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEImportedLogin : NSObject
- (instancetype)initWithSignonRealm:(NSString*)signonRealm
                          originURL:(NSString*)originURL
                          actionURL:(nullable NSString*)actionURL
                    usernameElement:(NSString*)usernameElement
                           username:(NSString*)username
                    passwordElement:(NSString*)passwordElement
                           password:(NSMutableData*)passwordUTF8  // empty for blocked entries
                             scheme:(NSInteger)scheme             // logins.scheme (0 HTML, 1 Basic, 2 Digest, 3 Other, 4 Username only)
                      blockedByUser:(BOOL)blockedByUser
                        dateCreated:(NSDate*)dateCreated
                       dateLastUsed:(nullable NSDate*)dateLastUsed
               datePasswordModified:(nullable NSDate*)datePasswordModified
                          timesUsed:(NSInteger)timesUsed
                               note:(nullable NSMutableData*)noteUTF8 NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEImportedCookie : NSObject
- (instancetype)initWithName:(NSString*)name
                       value:(NSMutableData*)valueUTF8
                      domain:(NSString*)hostKey          // ".example.com" or "example.com"
                        path:(NSString*)path
                    creation:(NSDate*)creation
                  expiration:(nullable NSDate*)expiration // nil = session cookie
                  lastAccess:(nullable NSDate*)lastAccess
                  lastUpdate:(nullable NSDate*)lastUpdate
                      secure:(BOOL)secure
                    httpOnly:(BOOL)httpOnly
                    sameSite:(NSInteger)sameSite          // cookies.samesite (-1 unspecified, 0 none, 1 lax, 2 strict)
                    priority:(NSInteger)priority          // cookies.priority (0 low, 1 medium, 2 high)
                sourceScheme:(NSInteger)sourceScheme      // cookies.source_scheme
                  sourcePort:(NSInteger)sourcePort        // cookies.source_port
             topFrameSiteKey:(nullable NSString*)topFrameSiteKey  // partitioned cookies; nil otherwise
        hasCrossSiteAncestor:(BOOL)hasCrossSiteAncestor NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEImportedAddress : NSObject
- (instancetype)initWithGUID:(NSString*)guid
                      fields:(NSDictionary<NSNumber*, NSString*>*)fields   // address_type_tokens.type → value (Chromium FieldType, same build)
         verificationStatuses:(NSDictionary<NSNumber*, NSNumber*>*)statuses // address_type_tokens.verification_status
                    useCount:(NSInteger)useCount
                     useDate:(NSDate*)useDate
                dateModified:(nullable NSDate*)dateModified
                languageCode:(nullable NSString*)languageCode NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEImportedCard : NSObject
- (instancetype)initWithGUID:(NSString*)guid
                  nameOnCard:(NSString*)nameOnCard
             expirationMonth:(NSInteger)month
              expirationYear:(NSInteger)year
                      number:(NSMutableData*)digitsASCII   // 12–19 digits, no spaces
                    nickname:(nullable NSString*)nickname
                    useCount:(NSInteger)useCount
                     useDate:(nullable NSDate*)useDate NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEImportResult : NSObject
@property(nonatomic, readonly) NSInteger added;
@property(nonatomic, readonly) NSInteger existing;   // already in Open; left as is (§8.4)
@property(nonatomic, readonly) NSInteger failed;     // rejected by Chromium's checks (bad cookie, empty profile, …)
@end

/// Each call writes one batch (at most 256 records) and completes on the main
/// thread only after the batch is durable (§8.3). Calls on one context run in
/// order. An ephemeral context fails with OEErrorDomain / OEErrorEphemeralContext
/// (code 7). Mock-key engines fail with OEErrorMockKeychain (code 8) unless
/// --open-allow-mock-keychain-secrets is present AND every record passes the
/// browser-process fixture check before any write: login realm and origin
/// hosts must be example.com, a subdomain of example.com, localhost or 127.0.0.1;
/// cookie domains (without a leading dot) must match those hosts; card numbers
/// must be one of the three public test numbers in plan §7.1. Addresses are
/// allowed with the switch. One non-fixture record rejects the whole batch
/// without writes. Real-key engines do not restrict records to fixture data.
@interface OEBrowserContext (SecretsImport)
- (void)importLogins:(NSArray<OEImportedLogin*>*)logins
          completion:(void (^)(OEImportResult* _Nullable result, NSError* _Nullable error))completion;
- (void)importAddresses:(NSArray<OEImportedAddress*>*)addresses
             completion:(void (^)(OEImportResult* _Nullable result, NSError* _Nullable error))completion;
- (void)importCards:(NSArray<OEImportedCard*>*)cards
         completion:(void (^)(OEImportResult* _Nullable result, NSError* _Nullable error))completion;
- (void)importCookies:(NSArray<OEImportedCookie*>*)cookies
           completion:(void (^)(OEImportResult* _Nullable result, NSError* _Nullable error))completion;
@end

@interface OEEngine (Autofill)
/// YES when the running engine has the 08xx patches and §5.3.
@property(nonatomic, readonly) BOOL supportsSecretsImport;
/// YES when the engine encrypts with the mock key (--use-mock-keychain).
/// --open-allow-mock-keychain-secrets lifts prompt suppression and permits
/// imports only after the fixture check above. It never permits real secrets.
@property(nonatomic, readonly) BOOL usesMockKeychain;
@end

NS_ASSUME_NONNULL_END
