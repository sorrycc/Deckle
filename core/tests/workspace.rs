use quill_core::workspace::Workspace;
use std::ffi::{c_char, c_int, c_void};

unsafe extern "C" fn event(_: *mut c_void, _: c_int, _: *const c_char) {}

fn wait_for(mut done: impl FnMut() -> bool) {
    for _ in 0..200 {
        if done() {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    panic!("timed out");
}

#[test]
fn indexes_lists_and_links() {
    let root = std::env::temp_dir().join(format!("quill-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("sub/.hidden")).unwrap();
    std::fs::write(root.join("Alpha.md"), "---\ntitle: \"Alpha Note\"\n---\n\n# Ignored heading\n\nSee [[Beta]] and [[sub/Gamma|the third]].\n\n![pic](pic.png)\n").unwrap();
    std::fs::write(root.join("Beta.md"), "# Beta title\n\nSome **bold** text with a [link](http://x.y) here.\n\n```\n[[Alpha]]\n```\n").unwrap();
    std::fs::write(root.join("sub/Gamma.md"), "第三篇笔记，链接到 [[alpha]] 两次 [[Alpha#part]]。\n").unwrap();
    std::fs::write(root.join("sub/.hidden/Secret.md"), "# hidden").unwrap();
    std::fs::write(root.join("pic.png"), [0u8; 4]).unwrap();

    let ws = Workspace::open(root.to_str().unwrap(), std::ptr::null_mut(), event);
    let dir = ws.root().to_string_lossy().into_owned();
    wait_for(|| ws.list_notes(&dir, true) == 3);
    let page: serde_json::Value = serde_json::from_str(&ws.notes_page(0, 10)).unwrap();
    assert_eq!(page[0]["title"], "Alpha Note");
    assert_eq!(page[0]["excerpt"], "See Beta and the third.");
    assert!(page[0]["image"].as_str().unwrap().ends_with("pic.png"));
    assert_eq!(page[1]["title"], "Beta title");
    assert_eq!(page[1]["excerpt"], "Some bold text with a link here.");
    assert_eq!(page[2]["title"], "Gamma");
    assert_eq!(ws.list_notes(&format!("{dir}/sub"), false), 1);

    let found: serde_json::Value = serde_json::from_str(&ws.find_files("gam", 10, false)).unwrap();
    assert_eq!(found[0]["rel"], "sub/Gamma.md");
    assert_eq!(found[0]["indices"], serde_json::json!([4, 5, 6]));

    let alpha = format!("{dir}/Alpha.md");
    let links: serde_json::Value = serde_json::from_str(&ws.backlinks(&alpha)).unwrap();
    assert_eq!(links.as_array().unwrap().len(), 1, "{links}");
    assert_eq!(links[0]["title"], "Gamma");
    assert_eq!(ws.resolve_link("Beta", &alpha), format!("{dir}/Beta.md"));
    assert_eq!(ws.resolve_link("sub/Gamma|x", &alpha), format!("{dir}/sub/Gamma.md"));
    assert_eq!(ws.resolve_link("gamma#h", &alpha), format!("{dir}/sub/Gamma.md"));
    assert_eq!(ws.resolve_link("Nope", &alpha), "");

    // The watcher takes in a new note and a removed one.
    std::fs::write(root.join("sub/Delta.md"), "# Delta\n").unwrap();
    wait_for(|| ws.list_notes(&dir, true) == 4);
    std::fs::remove_file(root.join("Beta.md")).unwrap();
    wait_for(|| ws.list_notes(&dir, true) == 3);
    ws.close();
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn titles_keep_dates_and_numbers() {
    let root = std::env::temp_dir().join(format!("quill-test-titles-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("a.md"), "# 2026-09-28\n\nToday.\n\n---\n\n## Notes\n").unwrap();
    std::fs::write(root.join("b.md"), "# 3 things\n\n1. one\n- [ ] two\n> three\n[x](http://a.b) four\n").unwrap();
    std::fs::write(root.join("c.md"), "# 1. Introduction\n\n*\t**bold** item\n").unwrap();
    let ws = Workspace::open(root.to_str().unwrap(), std::ptr::null_mut(), event);
    let dir = ws.root().to_string_lossy().into_owned();
    wait_for(|| ws.list_notes(&dir, true) == 3);
    let page: serde_json::Value = serde_json::from_str(&ws.notes_page(0, 10)).unwrap();
    assert_eq!(page[0]["title"], "1. Introduction");
    assert_eq!(page[0]["excerpt"], "bold item");
    assert_eq!(page[1]["title"], "2026-09-28");
    assert_eq!(page[1]["excerpt"], "Today.");
    assert_eq!(page[2]["title"], "3 things");
    assert_eq!(page[2]["excerpt"], "one two three x four");
    ws.close();
    let _ = std::fs::remove_dir_all(&root);
}
