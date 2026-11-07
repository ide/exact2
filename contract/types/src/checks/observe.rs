use super::{err, infer, Expr, Scope, Shapes, Span, Ty, TypeError};

/// Checks `observe(name[, Shape(key=value)[, severity]])`,
/// `observeAttributes(Shape(key=value))` and `observeError(message[, "TypeName"])`.
pub(super) fn args(
    name: &str,
    args: &[Expr],
    scope: &Scope,
    shapes: &Shapes,
    span: Span,
) -> Result<(), TypeError> {
    let (usage, max) = match name {
        "observe" => ("`observe(name)`, `observe(name, Shape(key=value))` or `observe(name, Shape(key=value), \"warn\")`", 3),
        "observeAttributes" => ("`observeAttributes(Shape(key=value))`", 1),
        _ => ("`observeError(message)` or `observeError(message, \"TypeName\")`", 2),
    };
    if args.is_empty() || args.len() > max {
        return err("type-observe", usage.to_string(), span);
    }
    for (i, arg) in args.iter().enumerate() {
        let ty = infer(arg, scope, shapes)?;
        let record = name == "observeAttributes" || (name == "observe" && i == 1);
        // The attributes must be constructed here: a record value carries no
        // field names for the host.
        let constructed = matches!(arg, Expr::Call(_, fields, _)
            if fields.iter().all(|f| matches!(f, Expr::NamedArg(..))));
        if record && !constructed {
            return err(
                "type-observe",
                format!("{usage}: the attributes are a shape constructed here, every field named"),
                arg.span(),
            );
        }
        let ok = if record {
            !matches!(ty, Ty::String | Ty::Number | Ty::Bool)
        } else {
            matches!(ty, Ty::String)
        };
        if !ok {
            return err(
                "type-observe",
                format!("{usage}: argument {} is `{ty}`", i + 1),
                arg.span(),
            );
        }
    }
    Ok(())
}
