def string_matching($pattern):
  type == "string" and test($pattern);

def hash:
  string_matching("^sha256:[0-9a-f]{64}$");

def scope:
  string_matching("^[a-z0-9][a-z0-9._:-]{2,127}$");

def deployment_id:
  string_matching("^dep_[0-9a-f]{32}$");

def batch_id:
  string_matching("^batch_[0-9a-f]{32}$");

def registry_key_id:
  string_matching("^rkey_[0-9a-f]{32}$");

def token:
  string_matching("^[!-~]{8,128}$");

def timestamp:
  string_matching("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?Z$");

def period:
  string_matching("^[0-9]{4}-(0[1-9]|1[0-2])$");

def checkpoint_date:
  string_matching("^[0-9]{4}-[0-9]{2}-[0-9]{2}$");

def base64_value:
  type == "string"
  and length >= 4
  and length <= 4096
  and test("^[A-Za-z0-9+/]+={0,2}$");

def registration_receipt_valid($state):
  type == "object"
  and .protocol_version == "1"
  and .registry_scope == $state.registry_scope
  and (.deployment_id | deployment_id)
  and .deployment_id == $state.deployment_id
  and (.registered_at | timestamp)
  and .public_key_fingerprint == $state.public_key_fingerprint
  and (.registry_key_id | registry_key_id)
  and (.registry_public_key | base64_value)
  and (.receipt_signature | base64_value)
  and (.duplicate | type == "boolean");

def installation_receipt_valid($state; $batch):
  type == "object"
  and (.ledger_index | type == "number" and . >= 1 and floor == .)
  and (.entry_hash | hash)
  and (.previous_entry_hash | hash)
  and (.batch_hash | hash)
  and .kind == "installation-test"
  and .period == $state.installation_period
  and .ruleset_version == "installation-test-v1"
  and .qualified_mau_count == 0
  and (.accepted_at | timestamp)
  and (.checkpoint_date | checkpoint_date)
  and .registry_scope == $state.registry_scope
  and (.registry_key_id | registry_key_id)
  and .registry_key_id == $state.registration.receipt.registry_key_id
  and (.registry_public_key | base64_value)
  and .registry_public_key == $state.registration.receipt.registry_public_key
  and (.signature | base64_value);

def installation_batch_valid($state):
  . as $batch
  | type == "object"
  and .protocol_version == "1"
  and .registry_scope == $state.registry_scope
  and (.batch_id | batch_id)
  and .deployment_id == $state.deployment_id
  and .idempotency_key == $state.installation_idempotency_key
  and (.duplicate | type == "boolean")
  and (.receipt | installation_receipt_valid($state; $batch));

def state_valid($expected_fingerprint):
  . as $state
  | type == "object"
  and .schema_version == 1
  and .protocol_version == "1"
  and (.registry_scope | scope)
  and .public_key_fingerprint == $expected_fingerprint
  and (.registration_idempotency_key | token)
  and (.registration_software_version
    | type == "string"
      and length >= 1
      and length <= 128
      and test("^[^\\r\\n]+$"))
  and (.installation_idempotency_key | token)
  and (.installation_period | period)
  and (.updated_at | timestamp)
  and (
    if .registration == null then
      .deployment_id == null
      and .trusted_registry_key_fingerprint == null
      and .installation_batch == null
    else
      (.deployment_id | deployment_id)
      and (.trusted_registry_key_fingerprint | hash)
      and (.registration
        | type == "object"
          and (.receipt | registration_receipt_valid($state)))
      and (
        .installation_batch == null
        or (.installation_batch | installation_batch_valid($state))
      )
    end
  );

if $mode == "state" then
  state_valid($expected_fingerprint)
elif $mode == "receipt" then
  ($state | length == 1)
  and ($state[0] | state_valid($expected_fingerprint))
  and installation_batch_valid($state[0])
else
  false
end
