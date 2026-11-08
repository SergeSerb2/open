# Imported secrets: fixture corrections

The generated two-Profile fixture uses valid UUID GUIDs for addresses and cards,
stored address field types, and a canonical cookie partition site. These are
fixture requirements, not changes to the engine's import policy.

- Address/card GUIDs must be UUIDs. The browser-process import checks them with
  `base::Uuid::ParseCaseInsensitive` in
  `Engine/fork/src/open/browser/autofill/open_profile_data_impl.cc:530,596`;
  the generated values are in `SyntheticSecretsFixture.createImportProfiles`.
- Street type 30 (`ADDRESS_HOME_LINE1`) is derived. Type 77
  (`ADDRESS_HOME_STREET_ADDRESS`) is stored. Name type 7 (`NAME_FULL`) is also
  stored. Evidence at Chromium commit
  `d0c02bfad08ec92a6ffcf989e53cd995e6381a4c`:
  [`field_types.h` lines 163/214](https://github.com/chromium/chromium/blob/d0c02bfad08ec92a6ffcf989e53cd995e6381a4c/components/autofill/core/browser/field_types.h#L163),
  [`autofill_profile.h` lines 210–213](https://github.com/chromium/chromium/blob/d0c02bfad08ec92a6ffcf989e53cd995e6381a4c/components/autofill/core/browser/data_model/addresses/autofill_profile.h#L210),
  and [`address_autofill_table.cc` lines 400–406/514](https://github.com/chromium/chromium/blob/d0c02bfad08ec92a6ffcf989e53cd995e6381a4c/components/autofill/core/browser/webdata/addresses/address_autofill_table.cc#L400).
- `CookiePartitionKey::FromStorage` uses strict schemeful-site parsing and
  requires the serialized result to equal the input. Evidence:
  [`cookie_partition_key.cc` lines 198–209/232–252](https://github.com/chromium/chromium/blob/d0c02bfad08ec92a6ffcf989e53cd995e6381a4c/net/cookies/cookie_partition_key.cc#L198).
  The synthetic Secure partitioned cookie uses canonical `https://localhost`.

The prior G3 real-App run passed I-1 after these fixture corrections. That result
does not prove later import rows or the real Keychain path. Current receipts
must identify their own App head and engine fingerprint.
