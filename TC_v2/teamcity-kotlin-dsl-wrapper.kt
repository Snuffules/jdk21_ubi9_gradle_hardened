gradle {
    name = "Gradle build"
    tasks = "clean build"

    useGradleWrapper = true

    dockerImage = "your-registry/ubi9-jdk21-teamcity-wrapper:latest"
    dockerRunParameters = """
        --user 185:0
        --cap-drop=ALL
        --security-opt=no-new-privileges
        --pids-limit=512
        --memory=4g
        --cpus=2
        --tmpfs /tmp:rw,nosuid,nodev,noexec,size=2g
    """.trimIndent()
}
