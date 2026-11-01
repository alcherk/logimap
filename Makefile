BINARY := .build/release/logimap
APP := build/Logimap.app
PREFIX := $(HOME)/Applications

.PHONY: build test app install uninstall run buttons doctor clean

build:
	swift build -c release

test:
	swift test 2>/dev/null | grep -E "Executed .* tests"

app: build
	@mkdir -p $(APP)/Contents/MacOS
	@cp $(BINARY) $(APP)/Contents/MacOS/logimap
	@cp Resources/Info.plist $(APP)/Contents/Info.plist
	@echo "→ $(APP)"

install: app
	@mkdir -p $(PREFIX)
	@rm -rf $(PREFIX)/Logimap.app
	@cp -R $(APP) $(PREFIX)/
	@$(PREFIX)/Logimap.app/Contents/MacOS/logimap install-agent
	@echo ""
	@echo "Готово. Если macOS спросит — разреши Logimap в:"
	@echo "  System Settings → Privacy & Security → Accessibility"

uninstall:
	@$(PREFIX)/Logimap.app/Contents/MacOS/logimap uninstall-agent 2>/dev/null || true
	@rm -rf $(PREFIX)/Logimap.app
	@echo "Удалено (конфиг ~/.config/logimap остался)"

run: build
	$(BINARY) run

buttons: build
	$(BINARY) buttons

doctor: build
	$(BINARY) doctor

clean:
	rm -rf .build build
