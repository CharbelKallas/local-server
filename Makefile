.PHONY: help vm-start vm-stop vm-status vm-ssh

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

vm-start: ## Start the Linux VM (creates it on first run)
	@scripts/vm-start.sh

vm-stop: ## Stop the Linux VM
	@scripts/vm-stop.sh

vm-status: ## Show Linux VM status
	@scripts/vm-status.sh

vm-ssh: ## Open a shell on the Linux VM
	@scripts/vm-ssh.sh
