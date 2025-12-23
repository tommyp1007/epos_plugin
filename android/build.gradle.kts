// android/build.gradle.kts

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Configure build directory
val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// --- COMBINED FIX FOR OLD PLUGINS (flutter_bluetooth_serial) ---
// This handles both the Namespace error and the Java 8 obsolete warning
subprojects {
    pluginManager.withPlugin("com.android.library") {
        try {
            val android = extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)
            if (android != null) {
                // 1. Fix Missing Namespace
                // Prevents "Namespace not specified" error in older plugins
                if (android.namespace == null) {
                    android.namespace = project.group.toString()
                }
                
                // 2. Force Java 17 Compatibility
                // Prevents "warning: [options] source value 8 is obsolete"
                android.compileOptions.sourceCompatibility = JavaVersion.VERSION_17
                android.compileOptions.targetCompatibility = JavaVersion.VERSION_17
            }
        } catch (e: Exception) {
            // Ignore errors if the extension class is not found or other issues occur
        }
    }
}