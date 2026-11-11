use super::*;

// ---------------------------------------------------------------------------
// Reference-aware validation discharge (esm-spec §9.6.9, Option B)
// ---------------------------------------------------------------------------

/// esm-spec §9.6.9: `makearray_region_inverted` is discharged at registration
/// on the composed, metaparameter-folded template bodies — region bounds cannot
/// carry template params (they are metaparameter expressions, §9.7.6), so the
/// check is instantiation-independent. Every retained template body (match and
/// match-less) is validated directly. Mirrors the Julia reference
/// `_validate_makearray_regions_in_registries`.
pub(super) fn validate_makearray_regions_in_registries(
    registries: &std::collections::HashMap<String, CompRegistry>,
) -> Result<(), ExpressionTemplateError> {
    for reg in registries.values() {
        for (tname, decl) in &reg.named {
            let body = decl_body(decl);
            if matches!(&*body, SNode::Null) {
                continue;
            }
            validate_makearray_regions(
                &to_value(&body),
                &format!("expression_templates.{tname}/body"),
            )?;
        }
    }
    Ok(())
}
