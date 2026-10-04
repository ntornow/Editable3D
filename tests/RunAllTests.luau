-- On-demand suites; every suite owns and releases temporary native objects.
return function(API, options)
	local report = { passed = 0, failed = 0, results = {}, suites = {} }
	local checkpoint = options and options.suiteCheckpoint
	assert(checkpoint == nil or type(checkpoint) == "function", "Suite checkpoint must be a function")
	for _, name in
		{
			"Tests",
			"TextureTests",
			"PatternTests",
			"AuthoringTests",
			"OperationBudgetTests",
			"GuardedImageTests",
			"PublishTests",
			"NativeContentTests",
			"NativePublishTests",
			"GeometryTests",
			"GLTFTests",
			"ShadingTests",
			"MotionTests",
			"GLTFMotionTests",
			"DynamicsTests",
			"ConstraintTests",
			"DeformationTests",
			"DeformWorkflowTests",
			"DeformMaskedTests",
			"ARAPTests",
			"NURBSTests",
			"NURBSEditTests",
			"HighDegreeSplineTests",
			"SplineFitTests",
			"NonlinearFitTests",
			"SplineDomainTests",
			"CyclicTests",
			"CyclicEditTests",
			"SurfaceEditTests",
			"SurfaceConstructionTests",
			"RationalCoonsTests",
			"SurfaceJoinTests",
			"SurfaceSeamTests",
			"SplineQueryTests",
			"SplineIntersectionTests",
			"SurfaceIntersectionTests",
			"SurfaceComponentTests",
			"SurfaceOrderingTests",
			"SurfaceQuotientTests",
			"BoundaryIdentityTests",
			"AffineContactTests",
			"PolynomialRootTests",
			"CurvePlaneTests",
			"AlgebraicFiberTests",
			"RuledPlaneTests",
			"RuledQuotientTests",
			"PlanarCADTests",
			"TensorPlaneTests",
			"GraphPairTests",
			"GeneralCADTests",
			"TensorPairTests",
			"PeriodicTensorTests",
			"RuledPairFixtureTests",
			"RuledPairTests",
			"RationalWindingTests",
			"VertexRegularizationTests",
			"FeatureRegularizationTests",
			"EdgeRegularizationTests",
			"IntervalArithmeticTests",
			"SurfaceAdaptiveTests",
			"PredicateTests",
			"PlanarTests",
			"PlanarConstraintTests",
			"SurfaceTrimTests",
			"SurfaceTrimAdaptiveTests",
			"TrimRegionTests",
			"IntersectionTests",
			"IntersectionRepairTests",
			"BooleanArrangementTests",
			"BuilderAttributeTests",
			"PlanarSimplifyTests",
			"UnsubdivideTests",
			"GridTransitionTests",
			"UVIslandTests",
			"AutomaticSeamTests",
			"AngleBasedTests",
			"UVRelaxTests",
			"FairingTests",
			"BrushTests",
			"DecimateTests",
			"QuadRetopologyTests",
			"ShellTests",
			"ProjectionTests",
			"MeshPrecisionTests",
			"AttributeTests",
			"SubdivisionCreaseTests",
			"SubdivisionFaceVaryingTests",
			"SubdivisionLimitTests",
			"SubdivisionFeatureTests",
			"FixedSectorTests",
			"JordanSectorTests",
			"ThreeSectorTests",
			"ConstrainedJetTests",
			"RegularVertexTests",
			"AnnularNormalTests",
			"SubdivisionHistoryTests",
			"NormalGermTests",
			"ConnectivityTests",
			"AttributeDomainTests",
			"ArcLengthTests",
			"BezierTests",
			"MeshEditTests",
			"MeshConstructionTests",
			"NormalTests",
			"BevelTests",
			"KnifeNetworkTests",
		}
	do
		if checkpoint then
			checkpoint({ suite = name, stage = "begin", passed = report.passed, failed = report.failed })
		end
		local result = require(script.Parent:FindFirstChild(name))(API, options)
		report.suites[name] = result
		report.passed += result.passed
		report.failed += result.failed
		for _, r in result.results do
			table.insert(report.results, r)
		end
		if checkpoint then
			checkpoint({ suite = name, stage = "complete", passed = report.passed, failed = report.failed })
		end
	end
	report.success = report.failed == 0
	return report
end
