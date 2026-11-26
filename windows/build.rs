fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    println!("cargo:rerun-if-changed=assets/spacetrail.rc");
    println!("cargo:rerun-if-changed=assets/spacetrail.manifest");
    println!("cargo:rerun-if-changed=assets/spacetrail.ico");
    println!("cargo:rerun-if-changed=assets/spacetrail.png");
    println!("cargo:rerun-if-changed=ui");
    embed_resource::compile("assets/spacetrail.rc", embed_resource::NONE)
        .manifest_required()
        .expect("could not embed the SpaceTrail icon and Windows manifest");

    use base64::{Engine, engine::general_purpose::STANDARD};
    let page = include_str!("ui/index.html")
        .replace(
            "<link rel=\"stylesheet\" href=\"ui.css\">",
            &format!("<style>{}</style>", include_str!("ui/ui.css")),
        )
        .replace(
            "src=\"app.js\"></script>",
            &format!(">{}</script>", include_str!("ui/app.js")),
        )
        .replace(
            "src=\"../assets/spacetrail.png\"",
            &format!(
                "src=\"data:image/png;base64,{}\"",
                STANDARD.encode(include_bytes!("assets/spacetrail.png"))
            ),
        );
    let output = std::path::PathBuf::from(std::env::var_os("OUT_DIR").expect("Cargo output"));
    std::fs::write(output.join("window.html"), page)
        .expect("could not embed the Windows interface");
}
