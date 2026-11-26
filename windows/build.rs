fn main() {
    println!("cargo:rerun-if-changed=assets/spacetrail.rc");
    println!("cargo:rerun-if-changed=assets/spacetrail.manifest");
    println!("cargo:rerun-if-changed=assets/spacetrail.ico");
    embed_resource::compile("assets/spacetrail.rc", embed_resource::NONE)
        .manifest_required()
        .expect("could not embed the SpaceTrail icon and Windows manifest");
}
