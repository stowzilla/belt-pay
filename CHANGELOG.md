# Changelog

## 0.1.0 (Unreleased)

- Initial release
- Stripe provider with customer provisioning, payment methods, checkout sessions
- Subscription management (create, cancel, billing portal)
- Transaction model for audit logging (DynamoDB)
- Billable concern for customer models
- Webhook handler with signature verification
- Generator: `belt g pay` (Terraform module, webhook Lambda, config, schema)
