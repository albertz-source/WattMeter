# 说明：默认走 scripts/build.sh（纯 clang + swiftc，无需 Xcode）。
# 有完整 Xcode 的环境可以用 `make swiftpm`。

.PHONY: build app run probe snapshot icon dmg clean swiftpm

build:
	./scripts/build.sh release

app: build
	@echo "App: dist/WattMeter.app"

run: build
	open dist/WattMeter.app

probe: build
	./.build/bin/wattprobe

icon:
	./scripts/make-icon.sh

dmg: build
	SKIP_BUILD=1 ./scripts/package-dmg.sh

snapshot: build
	./.build/bin/wattmeter-snapshot --view dashboard --state charging --out docs/preview-panel.png --width 400 --scale 2
	./.build/bin/wattmeter-snapshot --view dashboard --state battery  --out docs/preview-panel-battery.png --width 400 --scale 2
	./.build/bin/wattmeter-snapshot --view main --width 1020 --out docs/preview-window.png --scale 2

swiftpm:
	swift build -c release

clean:
	rm -rf .build dist
