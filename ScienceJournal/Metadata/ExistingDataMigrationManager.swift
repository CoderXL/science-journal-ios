/*
 *  Copyright 2019 Google Inc. All Rights Reserved.
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */

import UIKit

/// Errors that can be passed back by the existing data migration manager.
enum ExistingDataMigrationManagerError: Error {
  /// Error loading experiments from disk. Called with the IDs of the experiments.
  case experimentLoadError(experimentIDs: [String])
  /// Error saving experiments. Called with the IDs of the experiments.
  case experimentSaveError(experimentIDs: [String])
  /// Error fetching sensor data for trials. Called with the IDs of the trials.
  case sensorDataFetchError(trialIDs: [String])
  /// Error storing assets for the experiment. Called with the IDs of the experiments.
  case assetsSaveError(experimentIDs: [String])
  /// Error migrating the experiment because there wasn't enough disk space.
  case notEnoughFreeDiskSpaceToMigrate(experimentIDs: [String])
}

/// Manages migrating data from the pre-accounts root user to per-user storage, including
/// experiments, sensor data and preferences.
class ExistingDataMigrationManager {

  // MARK: - Properties

  /// The user manager for the user migrating data.
  let accountUserManager: UserManager

  /// The user manager for the pre-accounts root user.
  let rootUserManager: UserManager

  /// The number of existing experiments.
  var numberOfExistingExperiments: Int {
    return rootUserManager.metadataManager.experimentOverviews.count
  }

  /// Whether or not there are existing experiments.
  var hasExistingExperiments: Bool {
    return numberOfExistingExperiments > 0
  }

  private let migrationQueue = GSJOperationQueue()

  // MARK: - Public

  /// Designated initializer.
  ///
  /// - Parameters:
  ///   - accountUserManager: The user manager for the user migrating data.
  ///   - rootUserManager: The user manager for the pre-accounts root user.
  init(accountUserManager: UserManager, rootUserManager: UserManager) {
    self.accountUserManager = accountUserManager
    self.rootUserManager = rootUserManager

    // For memory performance, experiments migrate one at a time.
    migrationQueue.maxConcurrentOperationCount = 1
  }

  // MARK: Experiments

  private func canMigrateExperiment(withID experimentID: String) -> Bool {
    guard let sizeOfExperiment = sizeOfRootExperiment(withID: experimentID),
        let freeSize = FileManager.default.availableSystemDiskSpace else {
      return false
    }

    // Pad the size of the experiment as a safety measure.
    let safeSize = UInt64(Double(sizeOfExperiment) * 1.1)

    return freeSize > safeSize
  }

  private func sizeOfRootExperiment(withID experimentID: String) -> UInt64? {
    guard let experiment = rootUserManager.metadataManager.experiment(withID: experimentID) else {
      return nil
    }

    // The size of the experiments directory.
    let experimentURL = rootUserManager.metadataManager.experimentDirectoryURL(for: experimentID)
    guard let experimentDirectorySize =
        FileManager.default.sizeOfDirectory(at: experimentURL) else {
      return nil
    }

    // The size of the recordings in the database.
    let estimatedRecordingDatabaseSize =
        experiment.trials.map { $0.estimatedRecordingDatabaseSize }.reduce(0, +)

    return experimentDirectorySize + UInt64(estimatedRecordingDatabaseSize)
  }

  /// Moves an experiment from pre-account storage to storage for this user.
  ///
  /// - Parameters:
  ///   - experimentID: The ID of the experiment to migrate.
  ///   - completion: Called when migration is complete, with errors if any.
  func migrateExperiment(withID experimentID: String,
                         completion: @escaping ([ExistingDataMigrationManagerError]) -> Void) {
    guard let experimentAndOverview = self.rootUserManager.metadataManager.experimentAndOverview(
        forExperimentID: experimentID) else {
      completion([.experimentLoadError(experimentIDs: [experimentID])])
      return
    }

    guard canMigrateExperiment(withID: experimentID) else {
      completion([.notEnoughFreeDiskSpaceToMigrate(experimentIDs: [experimentID])])
      return
    }

    var migrateOperations = [GSJOperation]()

    // Migrate sensor data
    var errorTrialIDs = [String]()
    var previousMigrateTrial: GSJOperation?
    experimentAndOverview.experiment.trials.forEach { (trial) in
      let migrateTrial = GSJBlockOperation(block: { [unowned self] (finished) in
        let accountSensorDataManager = self.accountUserManager.sensorDataManager
        let rootSensorDataManager = self.rootUserManager.sensorDataManager
        accountSensorDataManager.countOfAllSensorData(forTrialID: trial.ID,
                                                      completion: { (accountCount) in
          rootSensorDataManager.countOfAllSensorData(forTrialID: trial.ID,
                                                     completion: { (rootCount) in
            var shouldMigrateSensorData = true
            if let accountCount = accountCount {
              if rootCount == accountCount {
                shouldMigrateSensorData = false
              } else if accountCount > 0 {
                accountSensorDataManager.removeDataAndWait(forTrialID: trial.ID)
              }
            }
            if shouldMigrateSensorData {
              rootSensorDataManager.fetchAllSensorData(forTrialID: trial.ID,
                                                       completion: { (sensorData, fetchContext) in
                if let sensorData = sensorData {
                  accountSensorDataManager.addSensorDataPoints(sensorData) { result in
                    switch result {
                    case .success(_): break
                    case .failure(_):
                      errorTrialIDs.append(trial.ID)
                    }
                    // Now that adding is complete, reset the fetch context to clear up memory.
                    fetchContext.reset()
                    finished()
                  }
                } else {
                  errorTrialIDs.append(trial.ID)
                  finished()
                }
              })
            } else {
              finished()
            }
          })
        })
      })

      // For memory performance, make trial migrations sequential.
      if let previousMigrateTrial = previousMigrateTrial {
        migrateTrial.addDependency(previousMigrateTrial)
      }
      previousMigrateTrial = migrateTrial
      migrateOperations.append(migrateTrial)
    }

    // Migrate experiment
    var addExperimentSuccess = false
    var saveAssetsSuccess = false

    let addExperimentAndCleanup = GSJBlockOperation { [unowned self] (finished) in
      guard errorTrialIDs.isEmpty else {
        finished()
        return
      }

      addExperimentSuccess = self.accountUserManager.metadataManager.addExperiment(
          experimentAndOverview.experiment, overview: experimentAndOverview.overview)
      saveAssetsSuccess = true
      if addExperimentSuccess {
        let rootAssetsURL =
            self.rootUserManager.metadataManager.assetsURL(for: experimentAndOverview.experiment)
        if FileManager.default.fileExists(atPath: rootAssetsURL.path) {
          let accountAssetsURL = self.accountUserManager.metadataManager.assetsURL(
              for: experimentAndOverview.experiment)
          do {
            try FileManager.default.moveItem(at: rootAssetsURL, to: accountAssetsURL)
          } catch {
            saveAssetsSuccess = false
            print("[ExistingDataMigrationManager] Error moving assets directory at " +
                      "'\(rootAssetsURL)' to '\(accountAssetsURL)': \(error.localizedDescription)")

            // If the asset folder move failed, don't continue.
            finished()
            return
          }
        }
        self.removeExperimentFromRootUser(withID: experimentID) {
          finished()
        }
      } else {
        finished()
      }
    }
    migrateOperations.forEach { addExperimentAndCleanup.addDependency($0) }
    migrateOperations.append(addExperimentAndCleanup)

    let migrate = GroupOperation(operations: migrateOperations)
    migrate.addObserver(BlockObserver { _, _ in
      // Errors
      var errors = [ExistingDataMigrationManagerError]()
      if !addExperimentSuccess {
        errors.append(.experimentSaveError(experimentIDs: [experimentID]))
      }
      if !errorTrialIDs.isEmpty {
        errors.append(.sensorDataFetchError(trialIDs: errorTrialIDs))
      }
      if !saveAssetsSuccess {
        errors.append(.assetsSaveError(experimentIDs: [experimentID]))
      }

      DispatchQueue.main.async {
        completion(errors)
      }
    })
    migrate.addObserver(BackgroundTaskObserver())

    migrationQueue.addOperation(migrate)
  }

  /// Moves all experiments from pre-account storage to storage for this user.
  ///
  /// - Parameter completion: Called when migration is complete, with errors if any.
  func migrateAllExperiments(completion: @escaping ([ExistingDataMigrationManagerError]) -> Void) {
    let dispatchGroup = DispatchGroup()
    var experimentLoadErrorIDs = [String]()
    var experimentSaveErrorIDs = [String]()
    var sensorDataFetchErrorIDs = [String]()
    var assetsSaveErrorIDs = [String]()
    var diskSpaceErrorIDs = [String]()
    let experimentIDs = rootUserManager.metadataManager.experimentOverviews.map { $0.experimentID }
    experimentIDs.forEach {
      dispatchGroup.enter()
      migrateExperiment(withID: $0) { errors in
        for error in errors {
          switch error {
          case .experimentLoadError(let experimentIDs):
            experimentLoadErrorIDs.append(contentsOf: experimentIDs)
          case .experimentSaveError(let experimentIDs):
            experimentSaveErrorIDs.append(contentsOf: experimentIDs)
          case .sensorDataFetchError(let trialIDs):
            sensorDataFetchErrorIDs.append(contentsOf: trialIDs)
          case .assetsSaveError(let experimentIDs):
            assetsSaveErrorIDs.append(contentsOf: experimentIDs)
          case .notEnoughFreeDiskSpaceToMigrate(let experimentIDs):
            diskSpaceErrorIDs.append(contentsOf: experimentIDs)
          }
        }
        dispatchGroup.leave()
      }
    }

    dispatchGroup.notify(qos: .userInitiated, queue: .global()) {
      var errors = [ExistingDataMigrationManagerError]()
      if !experimentLoadErrorIDs.isEmpty {
        errors.append(.experimentLoadError(experimentIDs: experimentLoadErrorIDs))
      }
      if !experimentSaveErrorIDs.isEmpty {
        errors.append(.experimentSaveError(experimentIDs: experimentSaveErrorIDs))
      }
      if !sensorDataFetchErrorIDs.isEmpty {
        errors.append(.sensorDataFetchError(trialIDs: sensorDataFetchErrorIDs))
      }
      if !assetsSaveErrorIDs.isEmpty {
        errors.append(.assetsSaveError(experimentIDs: assetsSaveErrorIDs))
      }
      if !diskSpaceErrorIDs.isEmpty {
        errors.append(.notEnoughFreeDiskSpaceToMigrate(experimentIDs: diskSpaceErrorIDs))
      }

      DispatchQueue.main.async {
        completion(errors)
      }
    }
  }

  /// Removes an experiment from pre-account storage.
  ///
  /// - Parameters:
  ///   - experimentID: The ID of the experiment to remove.
  ///   - completion: An optional closure called when the removal is finished.
  func removeExperimentFromRootUser(withID experimentID: String, completion: (() -> Void)? = nil) {
    self.rootUserManager.experimentDataDeleter.permanentlyDeleteExperiment(withID: experimentID,
                                                                           completion: completion)
  }

  /// Removes all experiments from pre-account storage.
  func removeAllExperimentsFromRootUser() {
    let experimentIDs = rootUserManager.metadataManager.experimentOverviews.map { $0.experimentID }
    experimentIDs.forEach {
      removeExperimentFromRootUser(withID: $0)
    }
  }

  // MARK: Preferences

  /// Moves preferences from pre-account user defaults to user defaults for this user.
  func migratePreferences() {
    accountUserManager.preferenceManager.migratePreferences(
        fromManager: rootUserManager.preferenceManager)
  }

  // MARK: Bluetooth Devices

  /// Removes all bluetooth devices for the root user, as bluetooth devices are not a supported
  /// migration data type and must be reconfigured in the future by signed in accounts.
  func removeAllBluetoothDevices() {
    rootUserManager.metadataManager.deleteAllBluetoothSensors()
  }

}
