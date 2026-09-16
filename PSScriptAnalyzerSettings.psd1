@{
    ExcludeRules = @(
        # Console output is the whole point of an installer.
        'PSAvoidUsingWriteHost'
    )
}
