# Throwaway PR-06 gate proof; never merged.
Describe 'PR-06 gate proof' {
    It 'planted known defect that still fails' -Tag 'KnownDefect' {
        1 | Should -Be 2
    }
    It 'planted ordinary failure without the tag' {
        1 | Should -Be 2
    }
}
