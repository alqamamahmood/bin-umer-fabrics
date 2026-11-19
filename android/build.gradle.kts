allprojects {
    repositories {
        maven { url = uri("file:///home/hatch/workspace/flutter-setup/m2repo") }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Har module (plugins samet) ek hi AndroidX version istemal kare —
// offline repo mein sirf ye versions maujood hain. :jni ko chhor kar,
// kyunke woh compileSdk 35 par hai aur core-ktx 1.17.0 ko 36 chahiye.
subprojects {
    // Firebase plugins + flutter_local_notifications compileSdk 34 par compile hote hain —
    // un par core 1.17.0 (compileSdk 36 mangta hai) force nahi karna, warna AAR metadata check fail hota hai.
    if (project.name != "jni" &&
        project.name != "cloud_firestore" &&
        project.name != "firebase_auth" &&
        project.name != "firebase_core" &&
        project.name != "firebase_messaging" &&
        project.name != "firebase_storage" &&
        project.name != "flutter_local_notifications") {
        configurations.all {
            resolutionStrategy {
                force("androidx.activity:activity:1.9.0")
                force("androidx.activity:activity-ktx:1.9.0")
                force("androidx.collection:collection:1.4.2")
                force("androidx.collection:collection-ktx:1.4.2")
                force("androidx.core:core:1.17.0")
                force("androidx.core:core-ktx:1.17.0")
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
