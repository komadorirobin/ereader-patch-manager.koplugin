ZIP_NAME := ereader-patch-manager.koplugin.zip
ROOT_DIR := ereader-patch-manager.koplugin

.PHONY: build clean test

build: clean
	@cd .. && zip -qr "$(ROOT_DIR)/$(ZIP_NAME)" "$(ROOT_DIR)" \
		-x "$(ROOT_DIR)/.git/*" \
		-x "$(ROOT_DIR)/tests/*" \
		-x "$(ROOT_DIR)/Makefile" \
		-x "$(ROOT_DIR)/README.md" \
		-x "$(ROOT_DIR)/.gitignore" \
		-x "$(ROOT_DIR)/$(ZIP_NAME)"
	@echo "Built $(ZIP_NAME)"

test:
	@sh tests/run.sh

clean:
	@rm -f "$(ZIP_NAME)"
