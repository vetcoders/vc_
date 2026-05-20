init:
	@echo You probably want to run "zig build" instead.
.PHONY: init

# glad updates the GLAD loader. To use this, place the generated glad.zip
# in this directory next to the Makefile, remove vendor/glad and run this target.
#
# Generator: https://gen.glad.sh/
glad: vendor/glad
.PHONY: glad

vendor/glad: vendor/glad/include/glad/gl.h vendor/glad/include/glad/glad.h

vendor/glad/include/glad/gl.h: glad.zip
	rm -rf vendor/glad
	mkdir -p vendor/glad
	unzip glad.zip -dvendor/glad
	find vendor/glad -type f -exec touch '{}' +

vendor/glad/include/glad/glad.h: vendor/glad/include/glad/gl.h
	@echo "#include <glad/gl.h>" > $@

clean:
	rm -rf \
		zig-out .zig-cache \
		macos/build \
		macos/GhosttyKit.xcframework
.PHONY: clean

# Build the vc_ (VC Underscore) runtime. The binary lands in
# zig-out/bin/vc_; a vc-term symlink is created at bundle time for
# environments that cannot render the trailing underscore.
vibecrafted:
	zig build -Druntime=vibecrafted
.PHONY: vibecrafted

# Convenience alias matching the new product mark.
vc:
	zig build -Druntime=vibecrafted
.PHONY: vc

bundle-linux:
	./distribution/bundle.sh --layout linux --output ./zig-out/bundle
.PHONY: bundle-linux

bundle-macos:
	./distribution/bundle.sh --layout macos --output ./zig-out/bundle
.PHONY: bundle-macos

tarball:
	./distribution/linux/build-tarball.sh
.PHONY: tarball

dmg:
	./distribution/macos/build-dmg.sh
.PHONY: dmg

wizard:
	@echo "Legacy Python installers are retired. Use \`make dmg\` on macOS or \`make tarball\` on Linux."
.PHONY: wizard

gui-install:
	@echo "Legacy GUI installer is retired. Use \`make dmg\` or open the packaged vc_.app bundle."
.PHONY: gui-install
