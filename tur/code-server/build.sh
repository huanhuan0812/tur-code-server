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

# 优化构建环境
export NODE_OPTIONS="--max_old_space_size=8192"
export npm_config_timeout=600000
export DISABLE_V8_COMPILE_CACHE=1

termux_step_post_get_source() {
	local f
	for f in $(cat ./patches/series); do
		echo "Applying patch: $(basename $f)"
		patch -d . -p1 < "./patches/$f";
	done

	# 修改所有 package.json 以支持 Node 24
	# echo "Patching package.json for Node 24 support..."
	# find . -name "package.json" -type f -exec sed -i 's/"node": "22"/"node": ">=22"/g' {} \;
	# find . -name "package.json" -type f -exec sed -i 's/"node": ">=22.0.0 <23.0.0"/"node": ">=22.0.0"/g' {} \;
	
	# 移除 --max-old-space-size 参数
	sed -i "s/--max-old-space-size=8192 / /g" lib/vscode/package.json 2>/dev/null || true

	# 移除这个标记
	rm -rf $TERMUX_HOSTBUILD_MARKER
}

# 设置 Node.js 24 用于宿主构建（x86_64）
_setup_nodejs_24_host() {
	local NODEJS_VERSION=24.17.0
	local NODEJS_FOLDER=${TERMUX_PKG_CACHEDIR}/build-tools/nodejs-${NODEJS_VERSION}

	if [ ! -x "$NODEJS_FOLDER/bin/node" ]; then
		mkdir -p "$NODEJS_FOLDER"
		local NODEJS_TAR_FILE=$TERMUX_PKG_TMPDIR/nodejs-$NODEJS_VERSION.tar.xz
		echo "Downloading Node.js ${NODEJS_VERSION} for host build..."
		
		# Node.js 24.17.0 x86_64 校验和
		termux_download https://nodejs.org/dist/v${NODEJS_VERSION}/node-v${NODEJS_VERSION}-linux-x64.tar.xz \
			"$NODEJS_TAR_FILE" \
			ab343a1b747c7cbf3630dfd7dbf818c5423fab2eb4f5ad1afc896f6bd121a917
		
		echo "Extracting Node.js..."
		tar -xf "$NODEJS_TAR_FILE" -C "$NODEJS_FOLDER" --strip-components=1
	fi
	export PATH="$NODEJS_FOLDER/bin:$PATH"
	echo "Node.js version: $(node --version)"
	echo "npm version: $(npm --version)"
}

# 重试函数
retry() {
	local max_attempts=3
	local attempt=1
	local delay=30
	while [ $attempt -le $max_attempts ]; do
		echo "Attempt $attempt of $max_attempts: $@"
		if "$@"; then
			return 0
		fi
		echo "Attempt $attempt failed. Retrying in $delay seconds..."
		sleep $delay
		attempt=$((attempt + 1))
	done
	return 1
}

termux_step_host_build() {
	export DISABLE_V8_COMPILE_CACHE=1
	export VERSION=$TERMUX_PKG_VERSION
	
	# 备份 bin 目录
	mv $TERMUX_PREFIX/bin $TERMUX_PREFIX/bin.bp 2>/dev/null || true
	
	# 安装系统依赖（x86_64 构建机）
	env -i PATH="$PATH" sudo apt update
	env -i PATH="$PATH" sudo apt install -yq libxkbfile-dev libsecret-1-dev libkrb5-dev
	
	# 设置 Node.js 24 用于宿主构建
	_setup_nodejs_24_host
	cd $TERMUX_PKG_SRCDIR
	
	echo "=== Installing npm dependencies ==="
	retry npm ci
	
	echo "=== Installing ternary-stream ==="
	retry npm install ternary-stream
	
	echo "=== Building code-server ==="
	retry npm run build
	
	echo "=== Building VSCode ==="
	retry npm run build:vscode
	
	echo "=== Creating release ==="
	retry npm run release
	
	mv $TERMUX_PREFIX/bin.bp $TERMUX_PREFIX/bin 2>/dev/null || true
}

termux_step_configure() {
	# 不需要额外配置，使用 Node.js 24
	:
}

termux_step_make() {
	export DISABLE_V8_COMPILE_CACHE=1
	export VERSION=$TERMUX_PKG_VERSION
	
	# 备份 bin 目录
	mv $TERMUX_PREFIX/bin $TERMUX_PREFIX/bin.bp 2>/dev/null || true

	# 设置架构
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

	# 创建 dummy librt.so
	rm -f $TERMUX_PREFIX/lib/librt.{so,a} 2>/dev/null || true
	echo "INPUT(-landroid-spawn)" >> $TERMUX_PREFIX/lib/librt.so

	# 构建 standalone 版本
	echo "=== Building standalone release ==="
	echo "Arch: $NPM_CONFIG_ARCH"
	echo "Start time: $(date)"
	
	if ! timeout 3600 npm run release:standalone; then
		echo "ERROR: release:standalone failed or timed out"
		exit 1
	fi
	
	echo "Finish time: $(date)"
	
	mv $TERMUX_PREFIX/bin.bp $TERMUX_PREFIX/bin 2>/dev/null || true
}

termux_step_make_install() {
	echo "=== Installing code-server ==="
	
	# 替换版本号
	npm version --prefix release-standalone "$VERSION" 2>/dev/null || true

	# 移除预编译的二进制文件（将在运行时替换）
	rm -f ./release-standalone/lib/node
	rm -f ./release-standalone/lib/vscode/node_modules/@vscode/ripgrep/bin/rg

	# 复制文件
	mkdir -p $TERMUX_PREFIX/lib/code-server
	cp -Rf ./release-standalone/* $TERMUX_PREFIX/lib/code-server/

	# 创建符号链接到 Termux 的 nodejs-lts
	# nodejs-lts 在 Termux 中位于 /opt/nodejs-lts/bin/node
	ln -sf $TERMUX_PREFIX/opt/nodejs-lts/bin/node $TERMUX_PREFIX/lib/code-server/lib/node
	ln -sf $TERMUX_PREFIX/bin/rg $TERMUX_PREFIX/lib/code-server/lib/vscode/node_modules/@vscode/ripgrep/bin/rg

	# 创建启动脚本
	cat << EOF > $TERMUX_PREFIX/bin/code-server
#!/data/data/com.termux/files/usr/bin/env sh
exec $TERMUX_PREFIX/lib/code-server/bin/code-server "\$@"
EOF
	chmod +x $TERMUX_PREFIX/bin/code-server

	# 移除 dummy librt.so
	rm -f $TERMUX_PREFIX/lib/librt.so 2>/dev/null || true
	
	echo "=== Installation complete ==="
	echo "code-server version: $VERSION"
	echo "Installed to: $TERMUX_PREFIX/lib/code-server"
	echo "Symlink: $TERMUX_PREFIX/bin/code-server"
}

# 清理函数
termux_step_clean() {
	echo "Cleaning up build directory..."
	rm -rf $TERMUX_PKG_BUILDDIR
}