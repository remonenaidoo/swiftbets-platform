COMPOSE := docker compose --project-directory compose -f compose/docker-compose.yml

.PHONY: env packages build up down reset ps logs topics backup restore-drill

env:
	@test -f compose/.env || cp compose/.env.example compose/.env
	@scripts/ensure-signing-key.sh

packages:
	@for repo in ../swiftbets-*/; do \
	  [ -f "$$repo/Directory.Packages.props" ] && scripts/fetch-shared-packages.sh "$$repo" || true; \
	done

build: env
	$(COMPOSE) build

up: env
	$(COMPOSE) up -d --build --wait

down:
	$(COMPOSE) down

reset: env
	$(COMPOSE) down -v
	$(COMPOSE) up -d --build --wait

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f --tail=100

topics:
	$(COMPOSE) run --rm topics

eval-live: ## Phase 3 gate: 4 faults x 3 runs against the live model (spends API credit)
	CONFIRM_SPEND=$(CONFIRM_SPEND) python3 eval/eval-live.py 3

k8s-up: ## Create a kind cluster and install the whole platform on it (images from ghcr :main)
	kind get clusters | grep -qx swiftbets || kind create cluster --config deploy/kind/cluster.yaml --wait 120s
	scripts/helm-deps.sh
	helm upgrade --install swiftbets charts/swiftbets -n swiftbets --create-namespace -f charts/swiftbets/values-local.yaml --wait --timeout 20m
	@echo "kubectl -n swiftbets port-forward svc/gateway 7100:8080, then http://127.0.0.1:7100"

k8s-down: ## Delete the kind cluster
	kind delete cluster --name swiftbets

dashboards: ## Regenerate the money-path and Steward Grafana dashboards
	python3 scripts/gen-dashboards.py

backup: ## Back up every database of the running stack into backups/<timestamp>/
	scripts/backup.sh

restore-drill: ## Restore the newest backup into scratch databases and verify it
	scripts/restore-drill.sh
