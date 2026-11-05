-include .env
export

COMPOSE := docker compose
LS_PATH ?= lakehouse

TOKEN := $(shell curl -s $(POLARIS_ENDPOINT_URL)/api/catalog/v1/oauth/tokens \
  -H "Polaris-Realm: $(POLARIS_REALM)" \
  -d grant_type=client_credentials -d client_id=root -d client_secret=s3cr3t \
  -d scope=PRINCIPAL_ROLE:ALL | jq -r .access_token)

AWS_CLI_ADMIN := docker run --rm --network polaris-seaweed-pilot \
	-e AWS_ACCESS_KEY_ID=$(ADMIN_KEY) -e AWS_SECRET_ACCESS_KEY=$(ADMIN_SECRET) \
	-e AWS_DEFAULT_REGION=us-east-1 \
	amazon/aws-cli \
	--endpoint-url http://s3:8333

AWS_CLI_POLARIS := docker run --rm --network polaris-seaweed-pilot \
	-e AWS_ACCESS_KEY_ID=$(POLARIS_S3_ACCESS_KEY) -e AWS_SECRET_ACCESS_KEY=$(POLARIS_S3_SECRET_KEY) \
	-e AWS_REGION=us-east-1 \
	amazon/aws-cli \
	--endpoint-url http://s3:8333

compose_up:
	$(COMPOSE) up -d --wait

create_bucket:
	$(AWS_CLI_ADMIN) s3 mb s3://$(BUCKET)

s3_ls:
	$(AWS_CLI_ADMIN) s3 ls $(LS_PATH)

# Python
set_python_venv:
	python3 -m venv .venv
	.venv/bin/pip install -r requirements.txt
d_ingest_data_bronze:
	.venv/bin/python3 scripts/bronze_ingestion.py

d_load_data_silver:
	.venv/bin/python3 scripts/silver_load.py

d_analysis::
	.venv/bin/python3 scripts/analysis.py

# Apache Polaris, Iceberg catalog

p_postgres_up:
	$(COMPOSE) up -d polaris-db --wait	

p_bootstrap:
	$(COMPOSE) run --rm polaris-bootstrap

p_up:
	$(COMPOSE) up -d polaris --wait

p_health:
	@curl -s http://localhost:8182/q/health | jq .status


p_create_catalog:
	@curl -X POST $(POLARIS_ENDPOINT_URL)/api/management/v1/catalogs \
	-H "Authorization: Bearer $(TOKEN)" -H "Polaris-Realm: $(POLARIS_REALM)" \
	-H "Content-Type: application/json" -d @catalog.json

p_list_catalog:
	@curl -s $(POLARIS_ENDPOINT_URL)/api/management/v1/catalogs -H "Authorization: Bearer $(TOKEN)" -H "Polaris-Realm: $(POLARIS_REALM)"

p_set_dbt_credentials:
# p_create_principal:
	@curl -X POST $(POLARIS_ENDPOINT_URL)/api/management/v1/principals \
	-H "Authorization: Bearer $(TOKEN)" -H "Polaris-Realm: $(POLARIS_REALM)" \
	-H "Content-Type: application/json" -d '{"principal": {"name": "$(POLARIS_PRINCIPAL)"}}'
# p_create_principal_role:
	@curl -X POST $(POLARIS_ENDPOINT_URL)/api/management/v1/principal-roles \
	-H "Authorization: Bearer $(TOKEN)" -H "Polaris-Realm: $(POLARIS_REALM)" \
	-H "Content-Type: application/json" -d '{"principalRole": {"name": "$(POLARIS_PRINCIPAL_ROLE)"}}'
# p_assign_principal_role:
	@curl -s -X PUT $(POLARIS_ENDPOINT_URL)/api/management/v1/principals/$(POLARIS_PRINCIPAL)/principal-roles \
	-H "Authorization: Bearer $(TOKEN)" -H "Polaris-Realm: $(POLARIS_REALM)" \
	-H "Content-Type: application/json" -d '{"principalRole": {"name": "$(POLARIS_PRINCIPAL_ROLE)"}}'
# p_create_catalog_role:
	@curl -s -X POST $(POLARIS_ENDPOINT_URL)/api/management/v1/catalogs/$(POLARIS_CATALOG)/catalog-roles \
	-H "Authorization: Bearer $(TOKEN)" -H "Polaris-Realm: $(POLARIS_REALM)" \
	-H "Content-Type: application/json" -d '{"catalogRole": {"name": "$(POLARIS_CATALOG_ROLE)"}}'
# p_assign_catalog_privilege:
	@curl -s -X PUT $(POLARIS_ENDPOINT_URL)/api/management/v1/catalogs/$(POLARIS_CATALOG)/catalog-roles/$(POLARIS_CATALOG_ROLE)/grants \
	-H "Authorization: Bearer $(TOKEN)" -H "Polaris-Realm: $(POLARIS_REALM)" \
	-H "Content-Type: application/json" -d '{"grant": {"type": "catalog", "privilege": "CATALOG_MANAGE_CONTENT"}}"'
# p_attach_catalog_role_to_principal_role:
	@curl -s -X PUT $(POLARIS_ENDPOINT_URL)/api/management/v1/principal-roles/$(POLARIS_PRINCIPAL_ROLE)/catalog-roles/$(POLARIS_CATALOG) \
	-H "Authorization: Bearer $(TOKEN)" -H "Polaris-Realm: $(POLARIS_REALM)" \
	-H "Content-Type: application/json" -d '{"catalogRole": {"name": "$(POLARIS_CATALOG_ROLE)"}}}'

p_list_credentials:
# p_list_principals:
	@echo 'principals:' && curl -s $(POLARIS_ENDPOINT_URL)/api/management/v1/principals \
	-H "Authorization: Bearer $(TOKEN)" -H "Polaris-Realm: $(POLARIS_REALM)" | jq
# p_list_principal_roles:
	@echo 'principal roles:' && curl -s $(POLARIS_ENDPOINT_URL)/api/management/v1/principals/$(POLARIS_PRINCIPAL)/principal-roles \
	-H "Authorization: Bearer $(TOKEN)" -H "Polaris-Realm: $(POLARIS_REALM)" | jq
# p_list_catalog_roles:
	@echo 'catalog roles:' && curl -s $(POLARIS_ENDPOINT_URL)/api/management/v1/catalogs/$(POLARIS_CATALOG)/catalog-roles \
	-H "Authorization: Bearer $(TOKEN)" -H "Polaris-Realm: $(POLARIS_REALM)" | jq
# p_list_grants:
	@echo 'grants:' && curl -s $(POLARIS_ENDPOINT_URL)/api/management/v1/catalogs/$(POLARIS_CATALOG)/catalog-roles/$(POLARIS_CATALOG_ROLE)/grants \
	-H "Authorization: Bearer $(TOKEN)" -H "Polaris-Realm: $(POLARIS_REALM)" | jq