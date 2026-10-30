# SOUQ engine

## Server configuration

Read once by the engine initializer at boot, without any database write:

| Variable                  | Default | Validation                                                   |
| ------------------------- | ------- | ------------------------------------------------------------ |
| `SOUQ_COUNTRY_CODE`       | `QA`    | Two uppercase ASCII letters (ISO alpha-2 format)             |
| `SOUQ_DEFAULT_CURRENCY`   | `QAR`   | Must belong to the allowed list                              |
| `SOUQ_ALLOWED_CURRENCIES` | `QAR`   | Nonempty comma-separated supported codes, whitespace trimmed |

Supported currency exponents: QAR, SAR, AED = 2; KWD, BHD, OMR = 3.
Unknown currencies, empty entries and invalid configuration abort boot.
`Souq.configuration` is immutable; changing environment variables after boot
does not change it. Restart the process to apply configuration changes.
No Railway variable is added by T9.

`Souq::Money.to_minor("12.50", currency: "QAR")` returns 1250.
`Souq::Money.to_decimal(1250, currency: "KWD")` returns `"1.250"`.
Only positive decimal strings and positive bigint integers are accepted.
Excess decimal places are rejected, never rounded, even trailing zeroes.
Conversion supports all six currencies; listing validation additionally
restricts currency to the configured server list.

## Data and development

`db/data/qa_locations.proposed.yml` is a bilingual proposal for ben's validation,
not an official or complete geographic dataset. No code loads this file.
Import belongs to T3. No data is loaded at boot or through migrations.
The explicit `souq:dev:demo_seed` task creates demo taxonomy and two demo
locations idempotently, and refuses production before database access.

## T9 scope

Listing attributes must remain `{}` until the attribute validator is delivered.
The listing model only accepts local non-reblog public/unlisted statuses owned
by its account. Creation flow and serializers are not implemented in T9.
Foreign keys handle physical status/account deletion by cascade; category and
location references restrict deletion. Category and location tree SQL is
installed both by migrations and after schema loading.
