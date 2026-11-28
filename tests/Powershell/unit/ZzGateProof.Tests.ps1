# Throwaway PR-06 gate proof; never merged.
Describe 'PR-06 gate proof' {
    It 'planted known defect that still fails' -Tag 'KnownDefect' {
        1 | Should -Be 2
    }
    It 'planted known defect that now passes' -Tag 'KnownDefect' {
        1 | Should -Be 1
    }
}
