group = "dev.fcwe1113.liveupdatecountdown"
version = "0.1.0"

plugins {
    id("com.android.library")
}

android {
    namespace = "dev.fcwe1113.liveupdatecountdown"
    compileSdk = flutter.compileSdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = 21
    }
}

dependencies {
    implementation("androidx.core:core:1.17.0")
}
