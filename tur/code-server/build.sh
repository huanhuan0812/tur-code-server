TERMUX_PKG_HOMEPAGE=https://github.com/coder/code-server
TERMUX_PKG_DESCRIPTION="Run VS Code on any machine anywhere and access it in the browser"
TERMUX_PKG_LICENSE="MIT"
TERMUX_PKG_MAINTAINER="@termux-user-repository"
TERMUX_PKG_VERSION="4.125.0"
TERMUX_PKG_SRCURL=git+https://github.com/coder/code-server
TERMUX_PKG_DEPENDS="libandroid-spawn, libsecret, krb5, nodejs-lts, ripgrep"
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_HOSTBUILD=true
TERMUX_PKG_NO_STATICSPLIT=true
TERMUX_PKG_EXCLUDED_ARCHES="i686"
TERMUX_PKG_ON_DEVICE_BUILD_NOT_SUPPORTED=true
TERMUX_PKG_AUTO_UPDATE=true
TERMUX_PKG_UPDATE_TAG_TYPE="latest-release-tag"

termux_step_post_get_source() {
	local f
	for f in $(cat ./patches/series); do
		echo "Applying patch: $(basename $f)"
		patch -d . -p1 < "./patches/$f";
	done

	# Ensure that code-server supports node 24 (nodejs-lts provides version 24.x)
	local _node_version=$(cat .node-version | cut -d. -f1 -)
	if [ "$_node_version" != 24 ]; then
		termux_error_exit "Version mismatch: Expected 24, got $_node_version."
	fi

	# Remove `--max-old-space-size=8192` from package.json
	sed -i "s/--max-old-space-size=8192 / /g" lib/vscode/package.json

	# Remove this marker all the time
	rm -rf $TERMUX_HOSTBUILD_MARKER
}

termux_step_host_build() {
	export DISABLE_V8_COMPILE_CACHE=1
	export VERSION=$TERMUX_PKG_VERSION
	mv $TERMUX_PREFIX/bin $TERMUX_PREFIX/bin.bp
	env -i PATH="$PATH" sudo apt update
	env -i PATH="$PATH" sudo apt install -yq libxkbfile-dev libsecret-1-dev libkrb5-dev
	# Node.js 24 is provided by nodejs-lts package, available in PATH
	cd $TERMUX_PKG_SRCDIR
	npm ci
	npm install ternary-stream
	npm run build
	npm run build:vscode
	npm run release
	mv $TERMUX_PREFIX/bin.bp $TERMUX_PREFIX/bin
}

termux_step_configure() {
	# Node.js 24 is provided by nodejs-lts package
	# No additional setup needed
	:
}

termux_step_make() {
	export DISABLE_V8_COMPILE_CACHE=1
	export VERSION=$TERMUX_PKG_VERSION
	mv $TERMUX_PREFIX/bin $TERMUX_PREFIX/bin.bp

	if [ $TERMUX_ARCH = "arm" ]; then
		export NPM_CONFIG_ARCH=armv7l
	elif [ $TERMUX_ARCH = "x86_64" ]; then
		export NPM_CONFIG_ARCH=amd64
	elif [ $TERMUX_ARCH = "aarch64" ]; then
		export NPM_CONFIG_ARCH=arm64
	else
		termux_error_exit "Unsupported arch: $TERMUX_ARCH"
	fi

	export npm_config_arch=$NPM_CONFIG_ARCH
	export npm_config_build_from_source=true

	# Create a dummy librt.so
	rm -f $TERMUX_PREFIX/lib/librt.{so,a}
	echo "INPUT(-landroid-spawn)" >> $TERMUX_PREFIX/lib/librt.so

	npm run release:standalone
	mv $TERMUX_PREFIX/bin.bp $TERMUX_PREFIX/bin
}

termux_step_make_install() {
	# Replace version
	npm version --prefix release-standalone "$VERSION"

	# Remove some pre-built binaries (currently nodejs and ripgrep) whose target is not Android
	rm ./release-standalone/lib/node
	rm ./release-standalone/lib/vscode/node_modules/@vscode/ripgrep/bin/rg

	# Copy release files of code-server
	mkdir -p $TERMUX_PREFIX/lib/code-server
	cp -Rf ./release-standalone/* $TERMUX_PREFIX/lib/code-server/

	# Replace nodejs - use system nodejs-lts from PATH
	ln -sf $TERMUX_PREFIX/bin/node $TERMUX_PREFIX/lib/code-server/lib/node

	# Replace ripgrep
	ln -sf $TERMUX_PREFIX/bin/rg $TERMUX_PREFIX/lib/code-server/lib/vscode/node_modules/@vscode/ripgrep/bin/rg

	# Create start script
	cat << EOF > $TERMUX_PREFIX/bin/code-server
#!$TERMUX_PREFIX/bin/env sh

exec $TERMUX_PREFIX/lib/code-server/bin/code-server "\$@"

EOF
	chmod +x $TERMUX_PREFIX/bin/code-server

	# Remove the dummy librt.so
	rm -f $TERMUX_PREFIX/lib/librt.so
}
