// A plain Kotlin JVM module, not an Android one, and that is the whole point.
//
// Everything in here is protocol: how the relay's SSE stream is framed, what a
// request carries, how events fold into an answer. None of it needs Android,
// and keeping it out of an Android module means its tests need no Android SDK
// either -- so they run in this repository's own build container, where
// dl.google.com is egress-blocked and the SDK cannot be installed at all.
//
// That turns the project's hardest constraint into a much smaller one: the
// logic worth testing is testable locally, and only the parts that genuinely
// need a phone are left for CI to compile and a device to prove.
plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

// Targets 17 without *requiring* a 17 toolchain. jvmToolchain(17) would demand
// that exact JDK be installed, which fails on a machine that has 21 -- and the
// point of this module is that it runs anywhere, including here. A JDK 21 can
// emit 17 bytecode perfectly well, and 17 is what the Android modules consume.
java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(libs.kotlinx.serialization.json)
    testImplementation(libs.junit)
}
