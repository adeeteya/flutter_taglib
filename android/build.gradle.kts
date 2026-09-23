group = "com.axel10.flutter_taglib"
version = "1.0"

plugins {
    id("com.android.library")
}

configure<com.android.build.api.dsl.LibraryExtension> {
    namespace = "com.axel10.flutter_taglib"
    compileSdk = 34

    defaultConfig {
        minSdk = 21
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("org.jetbrains.kotlin:kotlin-stdlib")
}
