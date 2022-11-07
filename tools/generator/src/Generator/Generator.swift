import PathKit
import XcodeProj

/// A class that generates and writes to disk an Xcode project.
///
/// The `Generator` class is stateless. It can be used to generate multiple
/// projects. The `generate()` method is passed all the inputs needed to
/// generate a project.
class Generator {
    static let defaultEnvironment = Environment(
        createProject: Generator.createProject,
        processReplacementLabels: Generator.processReplacementLabels,
        consolidateTargets: Generator.consolidateTargets,
        createFilesAndGroups: Generator.createFilesAndGroups,
        createProducts: Generator.createProducts,
        populateMainGroup: populateMainGroup,
        disambiguateTargets: Generator.disambiguateTargets,
        addBazelDependenciesTarget: Generator.addBazelDependenciesTarget,
        addTargets: Generator.addTargets,
        setTargetConfigurations: Generator.setTargetConfigurations,
        setTargetDependencies: Generator.setTargetDependencies,
        createCustomXCSchemes: Generator.createCustomXCSchemes,
        createAutogeneratedXCSchemes: Generator.createAutogeneratedXCSchemes,
        createXCSharedData: Generator.createXCSharedData,
        createXcodeProj: Generator.createXcodeProj,
        writeXcodeProj: Generator.writeXcodeProj
    )

    let environment: Environment
    let logger: Logger

    init(
        environment: Environment = Generator.defaultEnvironment,
        logger: Logger
    ) {
        self.logger = logger
        self.environment = environment
    }

    /// Generates an Xcode project for a given `Project`.
    func generate(
        buildMode: BuildMode,
        forFixtures: Bool,
        project: Project,
        xccurrentversions: [XCCurrentVersion],
        extensionPointIdentifiers: [TargetID: ExtensionPointIdentifier],
        directories: FilePathResolver.Directories,
        outputPath: Path
    ) throws {
        let pbxProj = environment.createProject(
            buildMode,
            forFixtures,
            project,
            directories
        )
        guard let pbxProject = pbxProj.rootObject else {
            throw PreconditionError(message: """
`rootObject` not set on `pbxProj`
""")
        }
        let mainGroup: PBXGroup = pbxProject.mainGroup

        var targets = project.targets
        try environment.processReplacementLabels(
            &targets,
            project.replacementLabels
        )

        let isUnfocusedDependencyTargetIDs = Set(
            targets.filter(\.value.isUnfocusedDependency).keys
        )
        for id in targets.keys {
            targets[id]!.dependencies.subtract(isUnfocusedDependencyTargetIDs)
        }

        let (
            files,
            rootElements,
            filePathResolver,
            resolvedExternalRepositories
        ) = try environment.createFilesAndGroups(
            pbxProj,
            buildMode,
            forFixtures,
            project.forceBazelDependencies,
            targets,
            project.extraFiles,
            xccurrentversions,
            directories,
            logger
        )

        let consolidatedTargets = try environment.consolidateTargets(
            targets,
            filePathResolver.xcodeGeneratedFiles,
            logger
        )
        let (products, productsGroup) = environment.createProducts(
            pbxProj,
            consolidatedTargets
        )
        environment.populateMainGroup(
            mainGroup,
            pbxProj,
            rootElements,
            productsGroup
        )

        let disambiguatedTargets = environment.disambiguateTargets(
            consolidatedTargets
        )
        let bazelDependencies = try environment.addBazelDependenciesTarget(
            pbxProj,
            buildMode,
            project.forceBazelDependencies,
            project.indexImport,
            files,
            filePathResolver,
            resolvedExternalRepositories,
            project.bazelConfig,
            project.generatorLabel,
            project.configuration,
            project.preBuildScript,
            project.postBuildScript,
            consolidatedTargets
        )
        let pbxTargets = try environment.addTargets(
            pbxProj,
            disambiguatedTargets,
            buildMode,
            products,
            files,
            filePathResolver,
            bazelDependencies
        )
        try environment.setTargetConfigurations(
            pbxProj,
            disambiguatedTargets,
            targets,
            buildMode,
            pbxTargets,
            project.targetHosts,
            bazelDependencies != nil,
            project.linkerProductsMap,
            filePathResolver
        )
        try environment.setTargetDependencies(
            buildMode,
            disambiguatedTargets,
            pbxTargets
        )

        let targetResolver = try TargetResolver(
            referencedContainer: filePathResolver.containerReference,
            targets: targets,
            targetHosts: project.targetHosts,
            extensionPointIdentifiers: extensionPointIdentifiers,
            consolidatedTargetKeys: disambiguatedTargets.keys,
            pbxTargets: pbxTargets
        )
        var schemes = try environment.createCustomXCSchemes(
            project.customXcodeSchemes,
            buildMode,
            targetResolver,
            project.runnerLabel,
            project.envs
        )
        let customSchemeNames = Set(schemes.map(\.name))
        schemes.append(contentsOf: try environment.createAutogeneratedXCSchemes(
            project.schemeAutogenerationMode,
            buildMode,
            targetResolver,
            customSchemeNames,
            project.envs
        ))
        let sharedData = environment.createXCSharedData(schemes)

        let xcodeProj = environment.createXcodeProj(pbxProj, sharedData)
        try environment.writeXcodeProj(
            xcodeProj,
            directories,
            files,
            outputPath
        )
    }
}
