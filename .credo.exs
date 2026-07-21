# Credo configuration for the image_plug library. Mirrors the policy
# used across the elixir-image libraries.
#
# The default strict suite runs with three policy adjustments:
#
# * Design.AliasUsage is disabled: the codebase intentionally uses
#   fully-qualified module names for one-off references rather than
#   aliasing every nested module at the top of each file.
#
# * Readability.AliasOrder is disabled: alias groups are ordered for
#   readability (primary collaborator first) rather than alphabetically.
#
# * Refactor.Nesting is disabled: the with/case/cond combinations used
#   for URL and option parsing commonly nest three to four levels and
#   read clearly.
%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "test/"],
        excluded: ["deps/", "_build/"]
      },
      checks: [
        {Credo.Check.Design.AliasUsage, false},
        {Credo.Check.Readability.AliasOrder, false},
        {Credo.Check.Refactor.Nesting, false}
      ]
    }
  ]
}
