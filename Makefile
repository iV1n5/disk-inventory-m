.PHONY: app run test ui-test icon

app:
	scripts/build-app.sh

run: app
	open "build/Disk Inventory M.app"

# Spelling out where the Swift Testing macros live works around a toolchain problem: without it,
# the first test run after any source change fails with "plugin for module 'TestingMacros' not found".
test:
	swift test --scratch-path .build/tests -Xswiftc -plugin-path \
		-Xswiftc "$$(dirname "$$(dirname "$$(xcrun -f swiftc)")")/lib/swift/host/plugins/testing"

# Opens a window for a minute or so, on a throwaway disk image.
ui-test:
	Tests/UI/run.sh

# Redraws the app icon. Only needed if its design changes.
icon:
	swift build -c release --product dim
	mkdir -p build
	"$$(swift build -c release --product dim --show-bin-path)/dim" icon build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
