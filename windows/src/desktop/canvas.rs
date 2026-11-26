use super::{shell::Thumbnail, text};
use spacetrail::{
    format_size,
    index::{Entry, Sample},
};
use std::mem::size_of;
use windows_sys::Win32::{Foundation::*, Graphics::Gdi::*};

const INDIGO: u32 = rgb(72, 65, 174);

const fn rgb(r: u8, g: u8, b: u8) -> u32 {
    (r as u32) | ((g as u32) << 8) | ((b as u32) << 16)
}

unsafe fn fill(dc: HDC, bounds: RECT, color: u32) {
    let brush = CreateSolidBrush(color);
    FillRect(dc, &bounds, brush);
    DeleteObject(brush);
}

unsafe fn label(dc: HDC, mut bounds: RECT, value: &str, color: u32) {
    SetTextColor(dc, color);
    SetBkMode(dc, TRANSPARENT as i32);
    let utf16 = text(value);
    DrawTextW(
        dc,
        utf16.as_ptr(),
        (utf16.len() - 1) as i32,
        &mut bounds,
        DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS,
    );
}

pub unsafe fn history(dc: HDC, bounds: RECT, samples: &[Sample]) {
    if bounds.bottom <= bounds.top {
        return;
    }
    let foreground = GetSysColor(COLOR_WINDOWTEXT);
    label(
        dc,
        RECT {
            bottom: bounds.top + 20,
            ..bounds
        },
        "Storage History",
        foreground,
    );
    let chart = RECT {
        top: bounds.top + 26,
        left: bounds.left + 70,
        right: bounds.right - 2,
        bottom: bounds.bottom - 8,
    };
    if samples.len() < 2 || chart.right <= chart.left || chart.bottom <= chart.top {
        label(
            dc,
            RECT {
                top: bounds.top + 27,
                ..bounds
            },
            "SpaceTrail shows storage history once it has samples from two different hours.",
            foreground,
        );
        return;
    }
    let used = |sample: &Sample| (sample.capacity - sample.free).max(0);
    let min = samples.iter().map(used).min().unwrap_or(0);
    let max = samples.iter().map(used).max().unwrap_or(0);
    let delta = (max - min).max(1);
    let span = (samples.last().unwrap().hour - samples[0].hour).max(1);
    let background = GetSysColor(COLOR_BTNFACE);
    for i in 0..=2 {
        let y = chart.top + (chart.bottom - chart.top) * i / 2;
        fill(
            dc,
            RECT {
                left: chart.left,
                right: chart.right,
                top: y,
                bottom: y + 1,
            },
            background,
        );
        label(
            dc,
            RECT {
                left: bounds.left,
                right: chart.left - 4,
                top: y - 8,
                bottom: y + 9,
            },
            &format_size(max - delta * i as i64 / 2),
            foreground,
        );
    }
    let pen = CreatePen(PS_SOLID, 2, INDIGO);
    let old = SelectObject(dc, pen);
    let points: Vec<_> = samples
        .iter()
        .map(|sample| POINT {
            x: chart.left
                + ((sample.hour - samples[0].hour) * (chart.right - chart.left) as i64 / span)
                    as i32,
            y: chart.bottom
                - ((used(sample) - min) * (chart.bottom - chart.top) as i64 / delta) as i32,
        })
        .collect();
    Polyline(dc, points.as_ptr(), points.len() as i32);
    SelectObject(dc, old);
    DeleteObject(pen);
}

pub fn tiles(bounds: RECT, rows: &[Entry]) -> Vec<(usize, RECT)> {
    if bounds.bottom <= bounds.top || bounds.right <= bounds.left {
        return Vec::new();
    }
    let counts = rows
        .iter()
        .enumerate()
        .filter(|(_, row)| row.allocated > 0)
        .take(28)
        .map(|(i, row)| (i, (row.allocated as f64).powf(0.8)))
        .collect::<Vec<_>>();
    let mut tiles = Vec::with_capacity(counts.len());
    place(bounds, &counts, &mut tiles);
    tiles
}

fn place(bounds: RECT, weights: &[(usize, f64)], out: &mut Vec<(usize, RECT)>) {
    if weights.is_empty() || bounds.right <= bounds.left || bounds.bottom <= bounds.top {
        return;
    }
    if weights.len() == 1 {
        out.push((weights[0].0, bounds));
        return;
    }
    let full: f64 = weights.iter().map(|(_, size)| size).sum();
    let mut part = 0.0;
    let mut split = 0;
    for (_, weight) in &weights[..weights.len() - 1] {
        part += weight;
        split += 1;
        if part >= full / 2.0 {
            break;
        }
    }
    let (first, rest) = weights.split_at(split);
    let ratio = part / full;
    if bounds.right - bounds.left >= bounds.bottom - bounds.top {
        let x = bounds.left + ((bounds.right - bounds.left) as f64 * ratio) as i32;
        place(RECT { right: x, ..bounds }, first, out);
        place(RECT { left: x, ..bounds }, rest, out);
    } else {
        let y = bounds.top + ((bounds.bottom - bounds.top) as f64 * ratio) as i32;
        place(
            RECT {
                bottom: y,
                ..bounds
            },
            first,
            out,
        );
        place(RECT { top: y, ..bounds }, rest, out);
    }
}

pub unsafe fn map(dc: HDC, bounds: RECT, rows: &[Entry]) {
    let tiles = tiles(bounds, rows);
    if tiles.is_empty() {
        label(
            dc,
            bounds,
            "The map appears as folder sizes are indexed.",
            GetSysColor(COLOR_WINDOWTEXT),
        );
        return;
    }
    let colors = [
        rgb(146, 58, 51),
        rgb(143, 76, 35),
        rgb(129, 68, 125),
        rgb(91, 70, 146),
        rgb(57, 84, 150),
        rgb(40, 100, 133),
        rgb(34, 100, 102),
        rgb(48, 90, 100),
    ];
    for (index, rect) in tiles {
        let rect = RECT {
            right: rect.right - 2,
            bottom: rect.bottom - 2,
            ..rect
        };
        if rect.right <= rect.left || rect.bottom <= rect.top {
            continue;
        }
        fill(dc, rect, colors[index.min(colors.len() - 1)]);
        if rect.right - rect.left >= 48 && rect.bottom - rect.top >= 20 {
            let inset = RECT {
                left: rect.left + 7,
                top: rect.top + 4,
                right: rect.right - 4,
                bottom: rect.bottom,
            };
            label(dc, inset, &rows[index].name, rgb(255, 255, 255));
            if rect.bottom - rect.top >= 44 {
                label(
                    dc,
                    RECT {
                        top: rect.bottom - 21,
                        ..inset
                    },
                    &format_size(rows[index].allocated),
                    rgb(255, 255, 255),
                );
            }
        }
    }
}

pub unsafe fn image(dc: HDC, bounds: RECT, thumbnail: &Thumbnail) {
    let bitmap = thumbnail.0 as HBITMAP;
    let mut info = BITMAP::default();
    if GetObjectW(
        bitmap,
        size_of::<BITMAP>() as i32,
        (&mut info as *mut BITMAP).cast(),
    ) == 0
        || info.bmWidth <= 0
        || info.bmHeight <= 0
        || bounds.right <= bounds.left
        || bounds.bottom <= bounds.top
    {
        return;
    }
    let scale = ((bounds.right - bounds.left) as f64 / info.bmWidth as f64)
        .min((bounds.bottom - bounds.top) as f64 / info.bmHeight as f64)
        .min(1.0);
    let w = (info.bmWidth as f64 * scale) as i32;
    let h = (info.bmHeight as f64 * scale) as i32;
    let memory = CreateCompatibleDC(dc);
    if memory.is_null() {
        return;
    }
    let previous = SelectObject(memory, bitmap);
    SetStretchBltMode(dc, HALFTONE);
    StretchBlt(
        dc,
        bounds.left + (bounds.right - bounds.left - w) / 2,
        bounds.top,
        w,
        h,
        memory,
        0,
        0,
        info.bmWidth,
        info.bmHeight,
        SRCCOPY,
    );
    SelectObject(memory, previous);
    DeleteDC(memory);
}
