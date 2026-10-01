# Secrets (D92, ADR 0004)

Third-party credentials for each environment live here as SOPS-encrypted dotenv files: `<env>.enc.env`, encrypted to
that environment's age public key. Only ciphertext is ever committed; `scripts/check-secrets.sh` fails CI on anything
else in this folder.

Generated infrastructure secrets (database passwords, the identity signing key) are not here: Terraform creates them
and writes `swiftbets-secrets`.

## Keys

| Name | Used by | Notes |
|---|---|---|
| `STRIPE_SECRET_KEY` | payments | Test-mode only (`sk_test_`); the adapter refuses live keys (D97) |
| `STRIPE_WEBHOOK_SECRET` | payments | Signs Stripe webhooks |
| `FEED_API_KEY` | offer | Real feed adapter, when enabled (D98) |
| `ANTHROPIC_API_KEY` | steward | Live diagnosis under the spend cap |
| `EMAIL_PROVIDER_API_KEY` | notifications | Real email delivery in staging |

## One-time setup per environment

```bash
age-keygen -o prod.agekey                      # keep the private key offline and in the GitHub environment secret
# put the printed public key into .sops.yaml for that environment, then:
cp secrets/example.env /tmp/prod.env && $EDITOR /tmp/prod.env
sops --encrypt --input-type dotenv --output-type dotenv /tmp/prod.env > secrets/prod.enc.env && shred -u /tmp/prod.env
```

Store the private key as the `SOPS_AGE_KEY` secret on the matching GitHub environment. The deploy job decrypts with it
at deploy time (`scripts/render-secrets.sh <env>`), and nothing decrypted is written to the repository, logs or images.

## Rotation

Generate a new age key, run `sops updatekeys secrets/<env>.enc.env` after updating `.sops.yaml`, replace the
environment secret, and redeploy. Rotate a credential itself by editing with `sops secrets/<env>.enc.env`.
