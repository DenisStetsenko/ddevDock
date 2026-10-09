APP      = ddevDock
BUNDLE   = $(APP).app
BIN      = .build/release/$(APP)
RES      = .build/release/$(APP)_$(APP).bundle
CONTENTS = $(BUNDLE)/Contents

.PHONY: app install clean

app: $(BUNDLE)

$(BIN): Sources/$(APP)/*.swift Package.swift
	swift build -c release

$(BUNDLE): $(BIN) Info.plist
	rm -rf $(BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BIN) $(CONTENTS)/MacOS/
	cp -R $(RES) $(CONTENTS)/Resources/
	cp Info.plist $(CONTENTS)/
	codesign --force --deep --sign - $(BUNDLE)

install: $(BUNDLE)
	rm -rf /Applications/$(BUNDLE)
	cp -R $(BUNDLE) /Applications/

clean:
	rm -rf $(BUNDLE) .build
