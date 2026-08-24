plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.tylerflores.pocketclaude.wear"
    compileSdk = 35

    defaultConfig {
        // Same applicationId as :app on purpose -- see that module's comment.
        applicationId = "com.tylerflores.pocketclaude"
        // Wear OS 4 is API 33; the Pixel Watch 2 shipped on it and takes
        // Wear OS 5 (API 34). 33 is the floor that reaches the watch as it
        // comes out of the box rather than only after it updates.
        minSdk = 33
        targetSdk = 34
        versionCode = 1
        versionName = "0.1"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.wear.compose.material)
    implementation(libs.androidx.wear.compose.foundation)
    implementation(libs.play.services.wearable)
    testImplementation(libs.junit)
}
