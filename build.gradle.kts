import java.util.Locale
import org.gradle.api.tasks.Copy
import org.gradle.api.tasks.Exec
import org.gradle.api.tasks.bundling.Zip

plugins {
    base
}

val konanVersion = (findProperty("kotlin.native.version") as? String)
    ?: (findProperty("kotlinVersion") as? String)
    ?: "2.2.20"

enum class HostPlatform { LINUX, MAC, WINDOWS }

data class RocksdbBuildConfig(
    val id: String,
    val konanTarget: String,
    val outputDirectoryName: String,
    val extraCFlags: () -> String,
    val extraCMakeFlags: () -> String,
    val buildScript: String,
    val buildArguments: List<String>,
    val artifactFileName: String,
    val host: HostPlatform
)

fun String.toTaskSuffix(): String = replaceFirstChar { ch ->
    if (ch.isLowerCase()) ch.titlecase(Locale.US) else ch.toString()
}

val isMacOs = System.getProperty("os.name").contains("Mac", ignoreCase = true)
val isWindows = System.getProperty("os.name").contains("win", ignoreCase = true)
val currentHost = when {
    isMacOs -> HostPlatform.MAC
    isWindows -> HostPlatform.WINDOWS
    else -> HostPlatform.LINUX
}

val hostArch = System.getProperty("os.arch")?.lowercase(Locale.US) ?: ""
fun isHostArmArch(): Boolean = hostArch.contains("arm") || hostArch.contains("aarch64")

fun resolveSdkPath(sdk: String): String = if (!isMacOs) {
    ""
} else {
    providers.exec { commandLine("xcrun", "--sdk", sdk, "--show-sdk-path") }
        .standardOutput
        .asText
        .get()
        .trim()
}

val iphoneOsSdk by lazy { resolveSdkPath("iphoneos") }
val iphoneSimulatorSdk by lazy { resolveSdkPath("iphonesimulator") }
val watchOsSdk by lazy { resolveSdkPath("watchos") }
val tvOsSdk by lazy { resolveSdkPath("appletvos") }

val buildConfigs = listOf(
    RocksdbBuildConfig(
        id = "linuxX64",
        konanTarget = "linux_x64",
        outputDirectoryName = "linux_x86_64",
        extraCFlags = { "-march=x86-64" },
        extraCMakeFlags = { "" },
        buildScript = "buildRocksdbLinux.sh",
        buildArguments = listOf("--arch=x86-64"),
        artifactFileName = "rocksdb-linux-x86_64.zip",
        host = HostPlatform.LINUX
    ),
    RocksdbBuildConfig(
        id = "linuxArm64",
        konanTarget = "linux_arm64",
        outputDirectoryName = "linux_arm64",
        extraCFlags = { "-march=armv8-a" },
        extraCMakeFlags = { "" },
        buildScript = "buildRocksdbLinux.sh",
        buildArguments = listOf("--arch=arm64"),
        artifactFileName = "rocksdb-linux-arm64.zip",
        host = HostPlatform.LINUX
    ),
    RocksdbBuildConfig(
        id = "macosX64",
        konanTarget = "macos_x64",
        outputDirectoryName = "macos_x86_64",
        extraCFlags = { "-arch x86_64 -target x86_64-apple-macos11.0" },
        extraCMakeFlags = { "-DPLATFORM=OS64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0" },
        buildScript = "buildRocksdbApple.sh",
        buildArguments = listOf("--platform=macos", "--arch=x86_64"),
        artifactFileName = "rocksdb-macos-x86_64.zip",
        host = HostPlatform.MAC
    ),
    RocksdbBuildConfig(
        id = "macosArm64",
        konanTarget = "macos_arm64",
        outputDirectoryName = "macos_arm64",
        extraCFlags = { "-arch arm64 -target arm64-apple-macos11.0" },
        extraCMakeFlags = { "-DPLATFORM=MAC -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0" },
        buildScript = "buildRocksdbApple.sh",
        buildArguments = listOf("--platform=macos", "--arch=arm64"),
        artifactFileName = "rocksdb-macos-arm64.zip",
        host = HostPlatform.MAC
    ),
    RocksdbBuildConfig(
        id = "iosArm64",
        konanTarget = "ios_arm64",
        outputDirectoryName = "ios_arm64",
        extraCFlags = {
            if (isMacOs) "-arch arm64 -target arm64-apple-ios13.0 -isysroot $iphoneOsSdk" else ""
        },
        extraCMakeFlags = { "-DPLATFORM=OS64" },
        buildScript = "buildRocksdbApple.sh",
        buildArguments = listOf("--platform=ios", "--arch=arm64"),
        artifactFileName = "rocksdb-ios-arm64.zip",
        host = HostPlatform.MAC
    ),
    RocksdbBuildConfig(
        id = "iosSimulatorArm64",
        konanTarget = "ios_simulator_arm64",
        outputDirectoryName = "ios_simulator_arm64",
        extraCFlags = {
            if (isMacOs) "-arch arm64 -target arm64-apple-ios13.0-simulator -isysroot $iphoneSimulatorSdk" else ""
        },
        extraCMakeFlags = { "-DPLATFORM=SIMULATORARM64" },
        buildScript = "buildRocksdbApple.sh",
        buildArguments = listOf("--platform=ios", "--simulator", "--arch=arm64"),
        artifactFileName = "rocksdb-ios-simulator-arm64.zip",
        host = HostPlatform.MAC
    ),
    RocksdbBuildConfig(
        id = "watchosArm64_32",
        konanTarget = "watchos_arm64_32",
        outputDirectoryName = "watchos_arm64_32",
        extraCFlags = {
            if (isMacOs) "-arch arm64_32 -target arm64_32-apple-watchos7.0 -isysroot $watchOsSdk" else ""
        },
        extraCMakeFlags = { "-DPLATFORM=WATCHOS -DARCHS=arm64_32 -DDEPLOYMENT_TARGET=7.0" },
        buildScript = "buildRocksdbApple.sh",
        buildArguments = listOf("--platform=watchos", "--arch=arm64_32"),
        artifactFileName = "rocksdb-watchos-arm64_32.zip",
        host = HostPlatform.MAC
    ),
    RocksdbBuildConfig(
        id = "watchosArm64",
        konanTarget = "watchos_arm64",
        outputDirectoryName = "watchos_arm64",
        extraCFlags = {
            if (isMacOs) "-arch arm64 -target arm64-apple-watchos7.0 -isysroot $watchOsSdk" else ""
        },
        extraCMakeFlags = { "-DPLATFORM=WATCHOS -DARCHS=arm64 -DDEPLOYMENT_TARGET=7.0" },
        buildScript = "buildRocksdbApple.sh",
        buildArguments = listOf("--platform=watchos", "--arch=arm64"),
        artifactFileName = "rocksdb-watchos-arm64.zip",
        host = HostPlatform.MAC
    ),
    RocksdbBuildConfig(
        id = "tvosArm64",
        konanTarget = "tvos_arm64",
        outputDirectoryName = "tvos_arm64",
        extraCFlags = {
            if (isMacOs) "-arch arm64 -target arm64-apple-tvos13.0 -isysroot $tvOsSdk" else ""
        },
        extraCMakeFlags = { "-DPLATFORM=TVOS -DARCHS=arm64" },
        buildScript = "buildRocksdbApple.sh",
        buildArguments = listOf("--platform=tvos", "--arch=arm64"),
        artifactFileName = "rocksdb-tvos-arm64.zip",
        host = HostPlatform.MAC
    ),
    RocksdbBuildConfig(
        id = "mingwX64",
        konanTarget = "mingw_x64",
        outputDirectoryName = "mingw_x86_64",
        extraCFlags = { "" },
        extraCMakeFlags = { "-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64" },
        buildScript = "buildRocksdbMinGW.sh",
        buildArguments = listOf("--arch=x86_64"),
        artifactFileName = "rocksdb-mingw-x86_64.zip",
        host = HostPlatform.LINUX
    )
)

val scriptsDirectory = layout.projectDirectory.dir("scripts")

buildConfigs.forEach { config ->
    val taskSuffix = config.id.toTaskSuffix()
    val requiresKonan = when {
        currentHost != config.host -> true
        currentHost != HostPlatform.LINUX -> true
        config.id == "linuxX64" -> false
        config.id == "linuxArm64" -> !isHostArmArch()
        else -> true
    }
    val prepareHeadersTask = tasks.register<Copy>("prepareHeaders$taskSuffix") {
        group = "build"
        description = "Copy RocksDB headers into build/include for ${config.id}"
        onlyIf { currentHost == config.host }
        from(project.file("rocksdb/include"))
        into(project.file("build/include/rocksdb"))
        doFirst {
            project.delete(project.file("build/include/rocksdb"))
        }
    }
    val prepareKonan = tasks.register("prepareKonan$taskSuffix", Exec::class) {
        group = "konan"
        description = "Download the Kotlin/Native toolchain for ${config.konanTarget}"
        onlyIf { currentHost == config.host && requiresKonan }
        commandLine(
            "bash",
            scriptsDirectory.file("install-konan.sh").asFile.absolutePath,
            "--target=${config.konanTarget}",
            "--konan-version=$konanVersion"
        )
    }

    val dependenciesTask = tasks.register("buildDependencies$taskSuffix", Exec::class) {
        group = "build"
        description = "Build RocksDB native dependencies for ${config.id}"
        onlyIf { currentHost == config.host }
        dependsOn(prepareKonan)
        doFirst {
            val dependencyArgs = listOf(
                "bash",
                project.file("buildDependencies.sh").absolutePath,
                "--extra-cflags",
                config.extraCFlags(),
                "--output-dir",
                project.file("build/lib/${config.outputDirectoryName}").absolutePath,
                "--extra-cmakeflags",
                config.extraCMakeFlags()
            )
            commandLine(dependencyArgs)
        }
        workingDir = projectDir
    }

    val buildTask = tasks.register("buildRocksdb$taskSuffix", Exec::class) {
        group = "build"
        description = "Build RocksDB static library for ${config.id}"
        onlyIf { currentHost == config.host }
        dependsOn(dependenciesTask)
        commandLine(
            listOf(
                "bash",
                project.file(config.buildScript).absolutePath
            ) + config.buildArguments
        )
        workingDir = project.projectDir
    }

    val packageTask = tasks.register("package${taskSuffix}", Zip::class) {
        group = "distribution"
        description = "Package RocksDB binaries for ${config.id}"
        onlyIf { currentHost == config.host }
        dependsOn(buildTask)
        dependsOn(prepareHeadersTask)
        archiveFileName.set(config.artifactFileName)
        destinationDirectory.set(layout.buildDirectory.dir("archives"))
        isPreserveFileTimestamps = false
        isReproducibleFileOrder = true

        from(project.file("build/include")) {
            include("**/*.h", "**/*.hh", "**/*.hpp", "**/*.hxx", "**/*.inc", "**/*.ipp")
            into("include")
        }
        from(project.file("build/lib/${config.outputDirectoryName}")) {
            include("**/*.a", "**/*.lib")
            into("lib")
        }
    }

    tasks.named("assemble") { dependsOn(packageTask) }
}
