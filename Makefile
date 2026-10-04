.PHONY: help vm-start vm-stop vm-status vm-ssh k3s-start k3s-stop k3s-status

help: ## Show this help message
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

vm-start: ## Start the Linux VM (creates it on first run)
	@scripts/vm-start.sh

vm-stop: ## Stop the Linux VM
	@scripts/vm-stop.sh

vm-status: ## Show Linux VM status
	@scripts/vm-status.sh

vm-ssh: ## Open a shell on the Linux VM
	@scripts/vm-ssh.sh

k3s-start: ## Start K3s service inside the VM
	@scripts/k3s-start.sh

k3s-stop: ## Stop K3s service inside the VM
	@scripts/k3s-stop.sh

k3s-status: ## Show K3s cluster status (nodes and system pods)
	@scripts/k3s-status.sh
