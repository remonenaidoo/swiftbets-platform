COMPOSE := docker compose --project-directory compose -f compose/docker-compose.yml

.PHONY: env packages build up down reset ps logs topics

env:
	@test -f compose/.env || cp compose/.env.example compose/.env

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
