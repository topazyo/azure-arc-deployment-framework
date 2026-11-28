# Throwaway PR-06 gate proof; never merged.
Describe 'PR-06 gate proof' {
    It 'planted known defect that still fails' -Tag 'KnownDefect' {
        1 | Should -Be 2
    }
}
