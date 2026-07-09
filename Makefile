# Drop this Makefile into the statuswatch repo root (alongside pipeline/).
# `make package` copies YOUR working pipeline code into each lambda zip —
# the code you validated locally is exactly what runs in the cloud.

PY_PLATFORM = --platform manylinux2014_x86_64 --only-binary=:all: --implementation cp --python-version 3.12

.PHONY: package up logs-poller logs-normalizer

package:
	rm -rf build && mkdir -p build/poller build/normalizer build/migrate
	# poller: handler + pipeline core/adapters/registry + aiohttp/yaml
	cp lambdas/poller/handler.py build/poller/
	cp pipeline/core.py pipeline/vendors.yaml build/poller/
	cp -r pipeline/adapters build/poller/adapters
	pip install aiohttp==3.11.11 PyYAML==6.0.2 -t build/poller/ $(PY_PLATFORM)
	# normalizer: handler + core (for materialize) + registry + psycopg2/yaml
	cp lambdas/normalizer/handler.py build/normalizer/
	cp pipeline/core.py pipeline/vendors.yaml build/normalizer/
	cp -r pipeline/adapters build/normalizer/adapters
	pip install psycopg2-binary==2.9.10 PyYAML==6.0.2 aiohttp==3.11.11 -t build/normalizer/ $(PY_PLATFORM)
	# migrate: handler + schema + psycopg2
	cp lambdas/migrate/handler.py build/migrate/
	cp pipeline/schema.sql build/migrate/
	pip install psycopg2-binary==2.9.10 -t build/migrate/ $(PY_PLATFORM)
	cd build/poller && zip -qr ../poller.zip .
	cd build/normalizer && zip -qr ../normalizer.zip .
	cd build/migrate && zip -qr ../migrate.zip .
	@echo "zips ready in build/"

up: package
	terraform -chdir=terraform init -input=false
	terraform -chdir=terraform apply

logs-poller:
	aws logs tail /aws/lambda/statuswatch-poller --follow

logs-normalizer:
	aws logs tail /aws/lambda/statuswatch-normalizer --follow
