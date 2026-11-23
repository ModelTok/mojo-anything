# frozen_string_literal: true

# A fixture for Ruby units ported to Mojo (`tests/ruby_mojo.rs`).
module Textkit
  # Repeats s n times; n must be 0 to 8.
  #
  # @param s [String]
  # @param n [Integer]
  # @return [String]
  def self.repeat(s, n)
    raise ArgumentError, "bad count" if n.negative? || n > 8

    s * n
  end

  # Returns v as it is: symbols, hashes with any keys, arrays.
  #
  # @param v [Object]
  # @return [Object]
  def self.echo(v)
    v
  end

  # Half of x.
  #
  # @param x [Float]
  # @return [Float]
  def self.half(x)
    x / 2.0
  end
end
