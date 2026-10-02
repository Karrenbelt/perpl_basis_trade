//! Rendering fixed-point chain integers as something a person can read.
//!
//! Every amount on both venues is a scaled integer in a different scale - AUSD
//! and USDC in 6, cbBTC in 8, WETH in 18, Perpl prices in whatever that
//! perpetual's `priceDecimals` says. Printing those raw is how an operator
//! misreads a position by three orders of magnitude.

use alloy::primitives::{I256, U256};

/// `value` scaled down by `decimals`, to `precision` decimal places, with
/// thousands separators on the integer part.
pub fn units(value: U256, decimals: u8, precision: usize) -> String {
    let scale = U256::from(10u64).pow(U256::from(decimals as u64));
    let whole = value / scale;
    let frac = value % scale;

    let mut out = group(&whole.to_string());
    if precision > 0 {
        // Pad the fraction to full width, then cut to the precision asked for,
        // so 0.5 AUSD reads 0.500000 rather than 0.5.
        let padded = format!("{:0>width$}", frac.to_string(), width = decimals as usize);
        let cut: String = padded.chars().take(precision).collect();
        out.push('.');
        out.push_str(&cut);
    }
    out
}

/// Signed counterpart of [`units`], always carrying an explicit sign.
pub fn signed_units(value: I256, decimals: u8, precision: usize) -> String {
    let negative = value.is_negative();
    let magnitude = U256::from_limbs(value.unsigned_abs().into_limbs());
    format!("{}{}", if negative { "-" } else { "+" }, units(magnitude, decimals, precision))
}

/// Parts per million as basis points, signed - the unit a trader reads a basis
/// in, where ppm is the unit the contract enforces it in.
pub fn ppm_as_bps(ppm: i64) -> String { format!("{:+.2}bp", ppm as f64 / 100.0) }

/// A Perpl price in PNS, rendered at that perpetual's own price scale.
pub fn price(pns: U256, price_decimals: u8) -> String { units(pns, price_decimals, 2) }

fn group(digits: &str) -> String {
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_six_decimal_stables() {
        assert_eq!(units(U256::from(35_000_000_000u64), 6, 6), "35,000.000000");
        assert_eq!(units(U256::from(1_287_431u64), 6, 6), "1.287431");
    }

    /// A fraction must keep its leading zeros or 0.012345 reads as 0.12345.
    #[test]
    fn pads_the_fraction() {
        assert_eq!(units(U256::from(12_345u64), 6, 6), "0.012345");
        assert_eq!(units(U256::from(500_000u64), 6, 6), "0.500000");
    }

    #[test]
    fn truncates_to_the_precision_asked_for() {
        assert_eq!(units(U256::from(1_287_431u64), 6, 2), "1.28");
        assert_eq!(units(U256::from(1_287_431u64), 6, 0), "1");
    }

    #[test]
    fn groups_thousands() {
        assert_eq!(units(U256::from(1_000_000_000_000u64), 6, 0), "1,000,000");
        assert_eq!(units(U256::from(999_000_000u64), 6, 0), "999");
    }

    #[test]
    fn signed_amounts_always_carry_a_sign() {
        assert_eq!(signed_units(I256::try_from(1_250_000i64).unwrap(), 6, 6), "+1.250000");
        assert_eq!(signed_units(I256::try_from(-1_250_000i64).unwrap(), 6, 6), "-1.250000");
        assert_eq!(signed_units(I256::ZERO, 6, 2), "+0.00");
    }

    #[test]
    fn ppm_reads_as_basis_points() {
        assert_eq!(ppm_as_bps(4349), "+43.49bp");
        assert_eq!(ppm_as_bps(-345), "-3.45bp");
    }
}
