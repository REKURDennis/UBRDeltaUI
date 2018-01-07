//
//  SectionDiffer.swift
//
//  Created by Karsten Bruns on 27/08/15.
//  Copyright © 2015 bruns.me. All rights reserved.
//

import Foundation


class SectionDiffer {
    
    typealias ElementUpdateHandler = (_ items: [AnyElement], _ section: Int, _ insertIndexPaths: [Int], _ reloadIndexPaths: [Int:Int], _ deleteIndexPaths: [Int]) -> ()
    typealias ElementReorderHandler = (_ items: [AnyElement], _ section: Int, _ reorderMap: [Int:Int]) -> ()
    typealias SectionUpdateHandler = (_ sections: [SectionElement], _ insertIndexSet: [Int], _ reloadIndexSet: [Int:Int], _ deleteIndexSet: [Int]) -> ()
    typealias SectionReorderHandler = (_ sections: [SectionElement], _ reorderMap: [Int:Int]) -> ()
    typealias StartHandler = () -> ()
    typealias CompletionHandler = () -> ()
    
    var throttleTimeInterval: Double = 0.2
    var debugOutput = false
    
    // Update handler
    var itemUpdate: ElementUpdateHandler? = nil
    var itemReorder: ElementReorderHandler? = nil
    var sectionUpdate: SectionUpdateHandler? = nil
    var sectionReorder: SectionReorderHandler? = nil
    
    var start: StartHandler? = nil
    var completion: CompletionHandler? = nil
    
    // State vars for background operations
    private var isDiffing: Bool = false
    private var resultIsOutOfDate: Bool = false
    
    // State vars to throttle UI update
    private var timeLockEnabled: Bool = false
    private var lastUpdateTime: Date = Date(timeIntervalSince1970: 0)
    
    // Section data
    private var oldSections: [SectionElement]? = nil
    private var newSections: [SectionElement]? = nil
    
    
    init() {}
    
    
    func queueComparison(oldSections: [SectionElement], newSections: [SectionElement]) {
        // Set Sections
        if self.oldSections == nil {
            // Old section should change only when a diff completes
            // and it got nilled
            self.oldSections = oldSections
        }
        
        // New section are always defined
        self.newSections = newSections
        
        // Guarding
        if isDiffing == true {
            // We declare the current result as out-of-date
            // because more recent 'newSections' are available
            self.resultIsOutOfDate = true
            return
        }
        
        diff()
    }
    
    
    private func diff() {
        // Guarding
        guard let oldSections = self.oldSections else { return }
        guard let newSections = self.newSections else { return }
        
        // Define State
        self.isDiffing = true
        self.resultIsOutOfDate = false

        // Do the diffing on a background thread
        let backgroundQueue = DispatchQueue.global(qos: .background)

        backgroundQueue.async {

            let reportDuplicatedElements = self.debugOutput
            
            // Diffing Elements
            var itemDiffs = [Int: ElementDifferResult]()
            for (oldSectionIndex, oldSection) in oldSections.enumerated() {
                
                let newIndex = newSections.index(where: { newSection -> Bool in
                    let isSame = newSection.uniqueIdentifier == oldSection.uniqueIdentifier
                    let isEqual = newSection.isEqual(to: oldSection)
                    return isSame && isEqual
                })
                
                if let newIndex = newIndex {
                    // Diffing
                    let oldElements = oldSection.subitems
                    let newElements = newSections[newIndex].subitems
                    let itemDiff = ElementDiffer.diff(old: oldElements, new: newElements, findDuplicatedElements: reportDuplicatedElements)
                    itemDiffs[oldSectionIndex] = itemDiff
                    
                    if reportDuplicatedElements {
                        if let duplicatedIndexes = itemDiff.duplicatedIndexes, duplicatedIndexes.count > 0 {
                            print("\n")
                            print("WARNING: Duplicated items detected. App will probably crash.")
                            print("Dublicated indexes:", duplicatedIndexes)
                            print("Dublicated items:", duplicatedIndexes.map({ newElements[$0] }))
                            print("\n")
                        }
                    }
                }
                
            }
            
            // Satisfy argument requirements of UBRDelta.diff()
            let oldSectionAsElements = oldSections.map({ $0 as AnyElement })
            let newSectionsAsElements = newSections.map({ $0 as AnyElement })
            
            // Diffing sections
            let sectionDiff = ElementDiffer.diff(old: oldSectionAsElements, new: newSectionsAsElements, findDuplicatedElements: reportDuplicatedElements)
            
            if reportDuplicatedElements {
                if let duplicatedIndexes = sectionDiff.duplicatedIndexes, duplicatedIndexes.count > 0 {
                    print("\n")
                    print("WARNING: Duplicated section items detected. App will probably crash.")
                    print("Dublicated indexes:", duplicatedIndexes)
                    print("Dublicated section items:", duplicatedIndexes.map({ newSections[$0] }))
                    print("\n")
                }
            }

            // Diffing is done - doing UI updates on the main thread
            let mainQueue = DispatchQueue.main
            mainQueue.async {
                
                // Guardings
                if self.resultIsOutOfDate == true {
                    // In the meantime 'newResults' came in, this means
                    // a new diff() and we are stopping the update
                    self.diff()
                    return
                }
                
                if self.timeLockEnabled == true {
                    // There is already a future diff() scheduled
                    // we are stopping here
                    return
                }
                
                let updateAllowedIn = self.lastUpdateTime.timeIntervalSinceNow + self.throttleTimeInterval
                if  updateAllowedIn > 0 {
                    // updateAllowedIn > 0 means the allowed update time is in the future
                    // so we schedule a new diff() for this point in time
                    self.timeLockEnabled = true
                    SectionDiffer.executeDelayed(updateAllowedIn) {
                        self.timeLockEnabled = false
                        self.diff()
                    }
                    return
                }
                
                // Calling the handler functions
                self.start?()
                
                // Element update for the old section order, because the sections
                // are not moved yet
                for (oldSectionIndex, itemDiff) in itemDiffs.sorted(by: { $0.0 < $1.0 }) {
                    
                    // Call element handler functions
                    self.itemUpdate?(
                        itemDiff.unmovedElements,
                        oldSectionIndex,
                        itemDiff.insertionIndexes,
                        itemDiff.reloadIndexMap,
                        itemDiff.deletionIndexes
                    )
                    self.itemReorder?(itemDiff.newElements, oldSectionIndex, itemDiff.moveIndexMap)
                }
                
                // Change type from Element to SectionElement.
                // Since this is expected to succeed a force unwrap is justified
                let updateElements = sectionDiff.unmovedElements.map({ $0 as! SectionElement })
                let reorderElements = sectionDiff.newElements.map({ $0 as! SectionElement })
                
                // Call section handler functions
                self.sectionUpdate?(updateElements, sectionDiff.insertionIndexes, sectionDiff.reloadIndexMap, sectionDiff.deletionIndexes)
                self.sectionReorder?(reorderElements, sectionDiff.moveIndexMap)
                
                // Call completion block
                self.completion?()
                
                // Reset state
                self.lastUpdateTime = Date()
                self.oldSections = nil
                self.newSections = nil
                self.isDiffing = false
            }
            
        }
        
    }
    
    
    static private func executeDelayed(_ time: Int, action: @escaping () -> ()) {
        self.executeDelayed(Double(time), action: action)
    }
    
    
    static private func executeDelayed(_ time: Double, action: @escaping () -> ()) {
        if time == 0 {
            action()
            return
        }
        
        let nanoSeconds: Int64 = Int64(Double(NSEC_PER_SEC) * time);
        let when = DispatchTime.now() + Double(nanoSeconds) / Double(NSEC_PER_SEC)

        DispatchQueue.main.asyncAfter(deadline: when, execute: {
            action()
        })
    }
}