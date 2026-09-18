# frozen_string_literal: true

module RubyDecisionModel
  # One entry from a provider's model list: a name the `model` field accepts,
  # what it is for, and when it shipped. An alias such as "jev-latest" is
  # listed the same way a versioned id is.
  ModelCard = Data.define(:name, :description, :release_date)
end
