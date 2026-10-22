// Run on a Mac:  swiftc -parse-as-library TrainModels.swift -o train && ./train
// (or paste into an Xcode macOS Command Line Tool target). Needs maintenance.csv + noshow.csv in the cwd.
import CreateML
import Foundation

@main
struct Trainer {
    static func main() throws {
        // 1) Predictive maintenance — regression: kmUntilDue per component
        let m = try MLDataTable(contentsOf: URL(fileURLWithPath: "maintenance.csv"))
        let (mTrain, mTest) = m.randomSplit(by: 0.8, seed: 42)
        let reg = try MLBoostedTreeRegressor(trainingData: mTrain, targetColumn: "kmUntilDue")
        let rm = reg.evaluation(on: mTest)
        print("Maintenance RMSE: \(rm.rootMeanSquaredError)  maxErr: \(rm.maximumError)")
        try reg.write(to: URL(fileURLWithPath: "MaintenancePredictor.mlmodel"),
                      metadata: MLModelMetadata(author: "Smart Garage", shortDescription: "Km until next service per component", version: "1.0"))

        // 2) No-show — binary classification
        let n = try MLDataTable(contentsOf: URL(fileURLWithPath: "noshow.csv"))
        let (nTrain, nTest) = n.randomSplit(by: 0.8, seed: 42)
        let clf = try MLBoostedTreeClassifier(trainingData: nTrain, targetColumn: "noShow")
        let cm = clf.evaluation(on: nTest)
        print("No-show classification error: \(cm.classificationError)")
        try clf.write(to: URL(fileURLWithPath: "NoShowClassifier.mlmodel"),
                      metadata: MLModelMetadata(author: "Smart Garage", shortDescription: "Probability an appointment is a no-show", version: "1.0"))
    }
}
