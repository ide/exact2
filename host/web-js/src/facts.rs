//! The runner's reserved sources the JS runtime answers itself (facts.js):
//! each declared reader's fields, checked against the runner's names.

use crate::emit::{type_code, type_json, value_js};
use exact_plan::{Plan, Value};
use std::fmt::Write as _;

/// The reserved sources facts.js answers (LLP 1071 §7): each declared
/// record's fields checked against the runner's names and passed by name;
/// `exactSurface` readers with their surface and shape. Returns the import.
pub fn reserved(plan: &Plan, body: &mut String) -> Result<String, String> {
    use exact_runner::{delivery, page, surface_record, viewport};
    let mut imports = Vec::new();
    for (source, fields, name) in [
        ("exactViewport", viewport::FIELDS, "viewport"),
        ("exactPage", page::FIELDS, "page"),
        ("exactDelivery", &delivery::FIELDS[..], "delivery"),
        ("exactSurface", &[][..], "surfaces"),
    ] {
        // Each reader by its resource name: its fields (by its own shape),
        // with what the build baked for delivery, or its surface and shape.
        let mut readers = Vec::new();
        for r in plan
            .resources
            .iter()
            .filter(|r| plan.str(r.source) == source)
        {
            let resource = plan.str(r.name);
            let t = &plan.types[r.ty.0 as usize];
            if t.kind != exact_plan::TypeKind::Record {
                return Err(format!("resource {resource}: `{source}` answers a record"));
            }
            let entry = if source == "exactSurface" {
                let surface = surface_record::surface_name(plan, r).ok_or_else(|| {
                    format!(
                        "resource {resource}: `exactSurface` takes one string-literal surface name"
                    )
                })?;
                format!(
                    "{},{}",
                    serde_json::to_string(surface).unwrap(),
                    type_json(plan, r.ty)
                )
            } else {
                let mut names = Vec::new();
                for f in t.fields.iter() {
                    let field = plan.str(plan.fields[f.0 as usize].name);
                    if !fields.contains(&field) {
                        return Err(format!("resource {resource}: `{source}` has no `{field}`"));
                    }
                    names.push(serde_json::to_string(field).unwrap());
                }
                let baked = plan.bytes(r.initial);
                if source == "exactDelivery" && !baked.is_empty() {
                    let v = Value::from_bytes(baked).map_err(|e| e.to_string())?;
                    format!("[{}],{}", names.join(","), value_js(&v))
                } else {
                    format!("[{}]", names.join(","))
                }
            };
            readers.push(format!(
                "{}:[{entry}]",
                serde_json::to_string(resource).unwrap()
            ));
        }
        if !readers.is_empty() {
            let _ = write!(body, "${name}({{{}}});", readers.join(","));
            imports.push(format!("{name} as ${name}"));
        }
    }
    Ok(if imports.is_empty() {
        String::new()
    } else {
        format!("import{{{}}}from\"./facts.js\";", imports.join(","))
    })
}

/// `res`'s last argument where a launch may keep the resource's answers
/// (LLP 1027 D4, kept.js): any source's but the runner's facts, which are
/// never kept (runner/src/runner/kept.rs), as [its identifying arguments'
/// count, its source's parameter type codes, whether the bake saw it read the
/// store]; empty for the rest.
pub fn keep(plan: &Plan, r: &exact_plan::ResourcesRow) -> String {
    use exact_runner::{delivery, page, surface_record, time, viewport};
    let source = plan.str(r.source);
    if [
        viewport::SOURCE,
        time::SOURCE,
        page::SOURCE,
        delivery::SOURCE,
        surface_record::SOURCE,
    ]
    .contains(&source)
    {
        return String::new();
    }
    let Some(s) = plan.sources.iter().find(|s| plan.str(s.name) == source) else {
        return String::new();
    };
    let params: String = s
        .params
        .iter()
        .map(|p| type_code(plan, plan.source_params[p.0 as usize].ty))
        .collect();
    format!(
        ",[{},{},{}]",
        r.args.len - u32::from(r.context),
        serde_json::to_string(&params).unwrap(),
        u8::from(r.reader)
    )
}
