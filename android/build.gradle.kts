// android/build.gradle.kts

allprojects {
    repositories {
        google()
        mavenCentral()
    }

    // ADD THIS BLOCK START
    tasks.withType<JavaCompile>().configureEach {
        options.compilerArgs.add("-Xlint:-options")
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

// --- FINAL FIXES ---
subprojects {
    // 1. FIX 'lStar not found' ERROR
    // Force older androidx.core version (1.6.0) which doesn't require Android 12 (API 31)
    project.configurations.all {
        resolutionStrategy {
            force("androidx.core:core:1.6.0")
            force("androidx.core:core-ktx:1.6.0")
        }
    }

    // 2. FIX 'Namespace not specified' ERROR (Safe Method)
    // We use withPlugin instead of afterEvaluate to avoid the crash
    pluginManager.withPlugin("com.android.library") {
        try {
            val android = extensions.findByName("android")
            if (android != null) {
                // Use reflection to set namespace safely if missing
                val getNamespace = android.javaClass.getMethod("getNamespace")
                val currentNamespace = getNamespace.invoke(android)
                
                if (currentNamespace == null) {
                    val setNamespace = android.javaClass.getMethod("setNamespace", String::class.java)
                    setNamespace.invoke(android, project.group.toString())
                }
            }
        } catch (e: Exception) {
            // Ignore reflection errors
        }
    }
}