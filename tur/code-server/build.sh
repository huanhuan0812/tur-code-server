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
export DISABLE_V8_COMPILE_CACHE=1

# npm 配置优化
export npm_config_timeout=600000
export npm_config_fetch_retry_mintimeout=20000
export npm_config_fetch_retry_maxtimeout=120000
export npm_config_loglevel=info
export npm_config_progress=true

termux_step_post_get_source() {
	local f
	for f in $(cat ./patches/series); do
		echo "Applying patch: $(basename $f)"
		patch -d . -p1 < "./patches/$f";
	done

	# 修改所有 package.json 以支持 Node 24
	echo "Patching package.json for Node 24 support..."
	find . -name "package.json" -type f -exec sed -i 's/"node": "22"/"node": ">=22"/g' {} \;
	find . -name "package.json" -type f -exec sed -i 's/"node": ">=22.0.0 <23.0.0"/"node": ">=22.0.0"/g' {} \;
	
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

# 增强的重试函数
retry() {
	local max_attempts=3
	local attempt=1
	local delay=30
	local cmd="$@"
	
	while [ $attempt -le $max_attempts ]; do
		echo "=========================================="
		echo "Attempt $attempt of $max_attempts: $cmd"
		echo "Time: $(date)"
		echo "=========================================="
		
		if eval "$cmd"; then
			echo "✅ Command succeeded on attempt $attempt"
			return 0
		fi
		
		local exit_code=$?
		echo "❌ Command failed with exit code $exit_code (attempt $attempt)"
		
		if [ $attempt -lt $max_attempts ]; then
			echo "Retrying in $delay seconds..."
			sleep $delay
			delay=$((delay * 2))  # 指数退避
		fi
		attempt=$((attempt + 1))
	done
	
	echo "❌ Command failed after $max_attempts attempts"
	return 1
}

# 带超时的命令执行
run_with_timeout() {
	local timeout_sec=$1
	shift
	local cmd="$@"
	
	echo "⏱️  Running with ${timeout_sec}s timeout: $cmd"
	if timeout $timeout_sec bash -c "$cmd"; then
		return 0
	else
		local exit_code=$?
		if [ $exit_code -eq 124 ]; then
			echo "❌ Command timed out after ${timeout_sec}s"
		else
			echo "❌ Command failed with exit code $exit_code"
		fi
		return $exit_code
	fi
}

termux_step_host_build() {
	export DISABLE_V8_COMPILE_CACHE=1
	export VERSION=$TERMUX_PKG_VERSION
	
	echo "=========================================="
	echo "Starting HOST BUILD phase"
	echo "Time: $(date)"
	echo "=========================================="
	
	# 备份 bin 目录
	mv $TERMUX_PREFIX/bin $TERMUX_PREFIX/bin.bp 2>/dev/null || true
	
	# 安装系统依赖（x86_64 构建机）
	echo "Installing system dependencies..."
	env -i PATH="$PATH" sudo apt update
	env -i PATH="$PATH" sudo apt install -yq libxkbfile-dev libsecret-1-dev libkrb5-dev
	
	# 设置 Node.js 24
	_setup_nodejs_24_host
	cd $TERMUX_PKG_SRCDIR
	
	# 第一步：安装主依赖
	echo "=========================================="
	echo "Step 1/7: Installing main dependencies (npm ci)"
	echo "Time: $(date)"
	echo "=========================================="
	
	if ! run_with_timeout 1800 "retry npm ci --no-optional --no-audit --progress=true"; then
		echo "⚠️  npm ci with --no-optional failed, trying with --ignore-scripts..."
		if ! run_with_timeout 1800 "retry npm ci --ignore-scripts --no-optional --no-audit"; then
			echo "❌ All npm ci attempts failed"
			exit 1
		fi
	fi
	echo "✅ npm ci completed at $(date)"
	
	# 第二步：安装 ternary-stream
	echo "=========================================="
	echo "Step 2/7: Installing ternary-stream"
	echo "Time: $(date)"
	echo "=========================================="
	
	if ! retry npm install ternary-stream --no-optional --no-audit; then
		echo "❌ Failed to install ternary-stream"
		exit 1
	fi
	echo "✅ ternary-stream installed at $(date)"
	
	# 第三步：安装 VSCode 依赖（分步执行，显示进度）
	echo "=========================================="
	echo "Step 3/7: Installing VSCode dependencies"
	echo "Time: $(date)"
	echo "This may take 5-15 minutes..."
	echo "=========================================="
	
	cd lib/vscode
	
	# VSCode 依赖可能很大，单独处理
	if ! run_with_timeout 1800 "retry npm install --no-optional --no-audit --progress=true"; then
		echo "⚠️  VSCode npm install failed, trying with --ignore-scripts..."
		if ! run_with_timeout 1800 "retry npm install --ignore-scripts --no-optional --no-audit"; then
			echo "❌ All VSCode npm install attempts failed"
			exit 1
		fi
	fi
	echo "✅ VSCode dependencies installed at $(date)"
	cd ../..
	
	# 第四步：构建 code-server
	echo "=========================================="
	echo "Step 4/7: Building code-server"
	echo "Time: $(date)"
	echo "=========================================="
	
	if ! retry npm run build --no-optional; then
		echo "❌ Failed to build code-server"
		exit 1
	fi
	echo "✅ code-server build completed at $(date)"
	
	# 第五步：构建 VSCode（最耗时）
	echo "=========================================="
	echo "Step 5/7: Building VSCode (this will take 15-25 minutes)"
	echo "Time: $(date)"
	echo "=========================================="
	
	if ! run_with_timeout 3600 "retry npm run build:vscode --no-optional"; then
		echo "❌ Failed to build VSCode"
		exit 1
	fi
	echo "✅ VSCode build completed at $(date)"
	
	# 第六步：创建 release
	echo "=========================================="
	echo "Step 6/7: Creating release"
	echo "Time: $(date)"
	echo "=========================================="
	
	if ! retry npm run release --no-optional; then
		echo "❌ Failed to create release"
		exit 1
	fi
	echo "✅ Release created at $(date)"
	
	# 恢复 bin 目录
	mv $TERMUX_PREFIX/bin.bp $TERMUX_PREFIX/bin 2>/dev/null || true
	
	echo "=========================================="
	echo "✅ HOST BUILD completed successfully"
	echo "Finish time: $(date)"
	echo "=========================================="
}

termux_step_configure() {
	# 不需要额外配置
	:
}

termux_step_make() {
	export DISABLE_V8_COMPILE_CACHE=1
	export VERSION=$TERMUX_PKG_VERSION
	
	echo "=========================================="
	echo "Starting MAKE phase (standalone release)"
	echo "Time: $(date)"
	echo "=========================================="
	
	# 备份 bin 目录
	mv $TERMUX_PREFIX/bin $TERMUX_PREFIX/bin.bp 2>/dev/null || true

	# 设置架构
	if [ $TERMUX_ARCH = "arm" ]; then
		export NPM_CONFIG_ARCH=armv7l
		echo "Architecture: arm (armv7l)"
	elif [ $TERMUX_ARCH = "x86_64" ]; then
		export NPM_CONFIG_ARCH=amd64
		echo "Architecture: x86_64 (amd64)"
	elif [ $TERMUX_ARCH = "aarch64" ]; then
		export NPM_CONFIG_ARCH=arm64
		echo "Architecture: aarch64 (arm64)"
	else
		termux_error_exit "Unsupported arch: $TERMUX_ARCH"
	fi

	export npm_config_arch=$NPM_CONFIG_ARCH
	export npm_config_build_from_source=true

	# 创建 dummy librt.so
	rm -f $TERMUX_PREFIX/lib/librt.{so,a} 2>/dev/null || true
	echo "INPUT(-landroid-spawn)" >> $TERMUX_PREFIX/lib/librt.so

	# 构建 standalone 版本
	echo "=========================================="
	echo "Step 7/7: Creating standalone release (npm run release:standalone)"
	echo "Arch: $NPM_CONFIG_ARCH"
	echo "Time: $(date)"
	echo "This will take 5-10 minutes..."
	echo "=========================================="
	
	if ! run_with_timeout 3600 "retry npm run release:standalone"; then
		echo "❌ Failed to create standalone release"
		exit 1
	fi
	
	echo "✅ Standalone release created at $(date)"
	
	# 恢复 bin 目录
	mv $TERMUX_PREFIX/bin.bp $TERMUX_PREFIX/bin 2>/dev/null || true
	
	echo "=========================================="
	echo "✅ MAKE phase completed successfully"
	echo "Finish time: $(date)"
	echo "=========================================="
}

termux_step_make_install() {
	echo "=========================================="
	echo "Starting INSTALL phase"
	echo "Time: $(date)"
	echo "=========================================="
	
	# 替换版本号
	npm version --prefix release-standalone "$VERSION" 2>/dev/null || true

	# 移除预编译的二进制文件（将在运行时替换）
	rm -f ./release-standalone/lib/node
	rm -f ./release-standalone/lib/vscode/node_modules/@vscode/ripgrep/bin/rg

	# 复制文件
	echo "Copying release files to $TERMUX_PREFIX/lib/code-server..."
	mkdir -p $TERMUX_PREFIX/lib/code-server
	cp -Rf ./release-standalone/* $TERMUX_PREFIX/lib/code-server/

	# 创建符号链接到 Termux 的 nodejs-lts
	echo "Creating symlinks..."
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
	
	echo "=========================================="
	echo "✅ INSTALLATION COMPLETE!"
	echo "=========================================="
	echo "code-server version: $VERSION"
	echo "Installed to: $TERMUX_PREFIX/lib/code-server"
	echo "Symlink: $TERMUX_PREFIX/bin/code-server"
	echo ""
	echo "To run: code-server"
	echo "=========================================="
}

# 清理函数
termux_step_clean() {
	echo "Cleaning up build directory..."
	rm -rf $TERMUX_PKG_BUILDDIR
}

# 错误处理
termux_step_on_error() {
	echo "=========================================="
	echo "❌ BUILD FAILED!"
	echo "=========================================="
	echo "Error time: $(date)"
	echo "Check the logs above for details."
	echo ""
	echo "Common issues:"
	echo "1. Network timeout - Check internet connection"
	echo "2. Out of memory - Add more memory or reduce parallel jobs"
	echo "3. Missing dependencies - Check apt packages"
	echo "=========================================="
}