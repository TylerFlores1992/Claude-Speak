// Deliberately empty of a `plugins { ... apply false }` block.
//
// That block is the conventional way to pin plugin versions in one place, but
// the version catalog already does that: each module's `alias(libs.plugins.x)`
// carries the version with it. Keeping the block here would resolve the Android
// Gradle Plugin whenever ANY task in this build is configured -- including
// :core:test, which has nothing to do with Android.
//
// That matters because AGP comes from dl.google.com, which is egress-blocked in
// this project's build container. With the block gone and configure-on-demand,
// `gradle :core:test` resolves nothing from Google and runs locally, which is
// the only way any of this code can be executed outside CI.
