/****************************************************************************
**
** Copyright (C) 2014 Digia Plc and/or its subsidiary(-ies).
** Copyright (C) 2013 Javier S. Pedro <maemo@javispedro.com>
** Contact: http://www.qt-project.org/legal
**
** This file is part of the QtBluetooth module of the Qt Toolkit.
**
** $QT_BEGIN_LICENSE:LGPL21$
** Commercial License Usage
** Licensees holding valid commercial Qt licenses may use this file in
** accordance with the commercial license agreement provided with the
** Software or, alternatively, in accordance with the terms contained in
** a written agreement between you and Digia. For licensing terms and
** conditions see http://qt.digia.com/licensing. For further information
** use the contact form at http://qt.digia.com/contact-us.
**
** GNU Lesser General Public License Usage
** Alternatively, this file may be used under the terms of the GNU Lesser
** General Public License version 2.1 or version 3 as published by the Free
** Software Foundation and appearing in the file LICENSE.LGPLv21 and
** LICENSE.LGPLv3 included in the packaging of this file. Please review the
** following information to ensure the GNU Lesser General Public License
** requirements will be met: https://www.gnu.org/licenses/lgpl.html and
** http://www.gnu.org/licenses/old-licenses/lgpl-2.1.html.
**
** In addition, as a special exception, Digia gives you certain additional
** rights. These rights are described in the Digia Qt LGPL Exception
** version 1.1, included in the file LGPL_EXCEPTION.txt in this package.
**
** $QT_END_LICENSE$
**
****************************************************************************/

#include "osx/osxbtutility_p.h"

#include "qlowenergyserviceprivate_p.h"
#include "qlowenergycontroller_osx_p.h"
#include "qbluetoothlocaldevice.h"
#include "qbluetoothdeviceinfo.h"
#include "qlowenergycontroller.h"
#include "qbluetoothuuid.h"

#include <QtCore/qloggingcategory.h>
#include <QtCore/qsharedpointer.h>
#include <QtCore/qbytearray.h>
#include <QtCore/qglobal.h>
#include <QtCore/qstring.h>
#include <QtCore/qlist.h>

#define OSX_D_PTR QLowEnergyControllerPrivateOSX *osx_d_ptr = static_cast<QLowEnergyControllerPrivateOSX *>(d_ptr)

QT_BEGIN_NAMESPACE

namespace {


class QLowEnergyControllerMetaTypes
{
public:
    QLowEnergyControllerMetaTypes()
    {
        qRegisterMetaType<QLowEnergyController::ControllerState>();
        qRegisterMetaType<QLowEnergyController::Error>();
    }
} qLowEnergyControllerMetaTypes;


typedef QSharedPointer<QLowEnergyServicePrivate> ServicePrivate;

// Convenience function, can return a smart pointer that 'isNull'.
ServicePrivate qt_createLEService(QLowEnergyControllerPrivateOSX *controller, CBService *cbService, bool included)
{
    Q_ASSERT_X(controller, "createLEService()", "invalid controller (null)");
    Q_ASSERT_X(cbService, "createLEService()", "invalid service (nil)");

    CBUUID *const cbUuid = cbService.UUID;
    if (!cbUuid) {
        qCDebug(QT_BT_OSX) << "createLEService(), invalid service, "
                              "UUID is nil";
        return ServicePrivate();
    }

    const QBluetoothUuid qtUuid(OSXBluetooth::qt_uuid(cbUuid));
    if (qtUuid.isNull()) // Conversion error is reported by qt_uuid.
        return ServicePrivate();

    ServicePrivate newService(new QLowEnergyServicePrivate);
    newService->uuid = qtUuid;
    newService->setController(controller);

    if (included)
        newService->type |= QLowEnergyService::IncludedService;

    // TODO: isPrimary is ... always 'NO' - to be investigated.
    /*
    #if QT_MAC_PLATFORM_SDK_EQUAL_OR_ABOVE(__MAC_10_9, __IPHONE_6_0)
    if (!cbService.isPrimary) {
        // Our guess included/not was probably wrong.
        newService->type &= ~QLowEnergyService::PrimaryService;
        newService->type |= QLowEnergyService::IncludedService;
    }
    #endif
    */
    // No such property before 10_9/6_0.
    return newService;
}

typedef QList<QBluetoothUuid> UUIDList;

UUIDList qt_servicesUuids(NSArray *services)
{
    QT_BT_MAC_AUTORELEASEPOOL;

    if (!services || !services.count)
        return UUIDList();

    UUIDList uuids;

    for (CBService *s in services)
        uuids.append(OSXBluetooth::qt_uuid(s.UUID));

    return uuids;
}

QLowEnergyHandle qt_findCharacteristicHandle(QLowEnergyHandle serviceHandle,
                                             CBService *service, CBCharacteristic *ch)
{
    // This mapping from CB -> Qt Qt -> CB is quite verbose and annoying,
    // but duplicating data structures (CB char-tree, Qt char-tree, etc.)
    // is even more annoying.

    Q_ASSERT_X(serviceHandle, "qt_findCharacteristicHandle",
               "invalid service handle (0)");
    Q_ASSERT_X(service, "qt_findCharacteristicHandle",
               "invalid service (nil)");
    Q_ASSERT_X(ch, "qt_findCharacteristicHandle",
               "invalid characteristic (nil)");

    NSArray *const chars = service.characteristics;
    if (!chars || !chars.count)
        return 0; // Invalid handle, to be .. handled by the caller.

    QLowEnergyHandle handle = serviceHandle + 1;
    for (CBCharacteristic *candidate in chars) {
        if (candidate == ch)
            return handle;
        NSArray *const ds = candidate.descriptors;
        if (ds && ds.count)
            handle += ds.count + 1; // + 1 is for char itself.
    }

    return 0;
}

}

QLowEnergyControllerPrivateOSX::QLowEnergyControllerPrivateOSX(QLowEnergyController *q)
    : q_ptr(q),
      isConnecting(false),
      lastError(QLowEnergyController::NoError),
      controllerState(QLowEnergyController::UnconnectedState),
      addressType(QLowEnergyController::PublicAddress),
      lastValidHandle(0) // 0 == invalid.
{
    // This is the "wrong" constructor - no valid device UUID to connect later.
    Q_ASSERT_X(q, "QLowEnergyControllerPrivate", "invalid q_ptr (null)");
    // We still create a manager, to simplify error handling later.
    centralManager.reset([[ObjCCentralManager alloc] initWithDelegate:this]);
    if (!centralManager) {
        qCWarning(QT_BT_OSX) << "QBluetoothLowEnergyControllerPrivateOSX::"
                                "QBluetoothLowEnergyControllerPrivateOSX(), "
                                "failed to initialize central manager";
    }

}

QLowEnergyControllerPrivateOSX::QLowEnergyControllerPrivateOSX(QLowEnergyController *q,
                                                               const QBluetoothDeviceInfo &deviceInfo)
    : q_ptr(q),
      deviceUuid(deviceInfo.deviceUuid()),
      isConnecting(false),
      lastError(QLowEnergyController::NoError),
      controllerState(QLowEnergyController::UnconnectedState),
      addressType(QLowEnergyController::PublicAddress),
      lastValidHandle(0) // 0 == invalid.
{
    Q_ASSERT_X(q, "QLowEnergyControllerPrivateOSX", "invalid q_ptr (null)");
    centralManager.reset([[ObjCCentralManager alloc] initWithDelegate:this]);
    if (!centralManager) {
        qCWarning(QT_BT_OSX) << "QBluetoothLowEnergyControllerPrivateOSX::"
                                "QBluetoothLowEnergyControllerPrivateOSX(), "
                                "failed to initialize central manager";
    }
}

QLowEnergyControllerPrivateOSX::~QLowEnergyControllerPrivateOSX()
{
}

bool QLowEnergyControllerPrivateOSX::isValid() const
{
    // isValid means only "was able to allocate all resources",
    // nothing more.
    return centralManager;
}

void QLowEnergyControllerPrivateOSX::LEnotSupported()
{
    // Report as an error. But this should not be possible
    // actually: before connecting to any device, we have
    // to discover it, if it was discovered ... LE _must_
    // be supported.
}

void QLowEnergyControllerPrivateOSX::connectSuccess()
{
    Q_ASSERT_X(controllerState == QLowEnergyController::ConnectingState,
               "connectSuccess", "invalid state");

    controllerState = QLowEnergyController::ConnectedState;

    if (!isConnecting) {
        emit q_ptr->stateChanged(QLowEnergyController::ConnectedState);
        emit q_ptr->connected();
    }
}

void QLowEnergyControllerPrivateOSX::serviceDiscoveryFinished(LEServices services)
{
    Q_ASSERT_X(controllerState == QLowEnergyController::DiscoveringState,
               "serviceDiscoveryFinished", "invalid state");

    using namespace OSXBluetooth;

    QT_BT_MAC_AUTORELEASEPOOL;

    // Now we have to traverse the discovered services tree.
    // Essentially it's an iterative version of more complicated code from the
    // OSXBTCentralManager's code.
    // All Obj-C entities either auto-release, or guarded by ObjCScopedReferences.
    if (services && [services count]) {
        QMap<QBluetoothUuid, CBService *> discoveredCBServices;
        //1. The first pass - none of this services is 'included' yet (we'll discover 'included'
        //   during the pass 2); we also ignore duplicates (== services with the same UUID)
        // - since we do not have a way to distinguish them later
        //   (our API is using uuids when creating QLowEnergyServices).
        for (CBService *cbService in services.data()) {
            const ServicePrivate newService(qt_createLEService(this, cbService, false));
            if (!newService.data())
                continue;
            if (discoveredServices.contains(newService->uuid)) {
                // It's a bit stupid we first created it ...
                qCDebug(QT_BT_OSX) << "QLowEnergyControllerPrivateOSX::serviceDiscoveryFinished(), "
                                   << "discovered service with a duplicated UUID "<<newService->uuid;
                continue;
            }
            discoveredServices.insert(newService->uuid, newService);
            discoveredCBServices.insert(newService->uuid, cbService);
        }

        ObjCStrongReference<NSMutableArray> toVisit([[NSMutableArray alloc] initWithArray:services], false);
        ObjCStrongReference<NSMutableArray> toVisitNext([[NSMutableArray alloc] init], false);
        ObjCStrongReference<NSMutableSet> visited([[NSMutableSet alloc] init], false);

        while (true) {
            for (NSUInteger i = 0, e = [toVisit count]; i < e; ++i) {
                CBService *const s = [toVisit objectAtIndex:i];
                if (![visited containsObject:s]) {
                    [visited addObject:s];
                    if (s.includedServices && s.includedServices.count)
                        [toVisitNext addObjectsFromArray:s.includedServices];
                }

                const QBluetoothUuid uuid(qt_uuid(s.UUID));
                if (discoveredServices.contains(uuid) && discoveredCBServices.value(uuid) == s) {
                    ServicePrivate qtService(discoveredServices.value(uuid));
                    // Add included UUIDs:
                    qtService->includedServices.append(qt_servicesUuids(s.includedServices));
                }// Else - we ignored this CBService object.
            }

            if (![toVisitNext count])
                break;

            for (NSUInteger i = 0, e = [toVisitNext count]; i < e; ++i) {
                CBService *const s = [toVisitNext objectAtIndex:i];
                const QBluetoothUuid uuid(qt_uuid(s.UUID));
                if (discoveredServices.contains(uuid)) {
                    if (discoveredCBServices.value(uuid) == s) {
                        ServicePrivate qtService(discoveredServices.value(uuid));
                        qtService->type |= QLowEnergyService::IncludedService;
                    } // Else this is the duplicate we ignored already.
                } else {
                    // Oh, we do not even have it yet???
                    ServicePrivate newService(qt_createLEService(this, s, true));
                    discoveredServices.insert(newService->uuid, newService);
                    discoveredCBServices.insert(newService->uuid, s);
                }
            }

            toVisit.resetWithoutRetain(toVisitNext.take());
            toVisitNext.resetWithoutRetain([[NSMutableArray alloc] init]);
        }
    } else {
        qCDebug(QT_BT_OSX) << "QLowEnergyControllerPrivateOSX::serviceDiscoveryFinished(), "
                              "no services found";
    }

    foreach (const QBluetoothUuid &uuid, discoveredServices.keys()) {
        QMetaObject::invokeMethod(q_ptr, "serviceDiscovered", Qt::QueuedConnection,
                                 Q_ARG(QBluetoothUuid, uuid));
    }

    controllerState = QLowEnergyController::DiscoveredState;
    QMetaObject::invokeMethod(q_ptr, "stateChanged", Qt::QueuedConnection,
                              Q_ARG(QLowEnergyController::ControllerState, controllerState));
    QMetaObject::invokeMethod(q_ptr, "discoveryFinished", Qt::QueuedConnection);
}

void QLowEnergyControllerPrivateOSX::serviceDetailsDiscoveryFinished(LEService service)
{
    Q_ASSERT_X(!service.isNull(), "serviceDetailsDiscoveryFinished",
               "invalid service (null)");

    QT_BT_MAC_AUTORELEASEPOOL;

    if (!discoveredServices.contains(service->uuid)) {
        qCDebug(QT_BT_OSX) << "QLowEnergyControllerPrivateOSX::serviceDetailsDiscoveryFinished(), "
                              "unknown service uuid: " << service->uuid;
        return;
    }

    ServicePrivate qtService(discoveredServices.value(service->uuid));
    // Assert on handles?
    qtService->startHandle = service->startHandle;
    qtService->endHandle = service->endHandle;
    qtService->characteristicList = service->characteristicList;

    qtService->stateChanged(QLowEnergyService::ServiceDiscovered);
}

void QLowEnergyControllerPrivateOSX::characteristicWriteNotification(LECharacteristic ch)
{
    Q_ASSERT_X(ch, "characteristicWriteNotification", "invalid characteristic (nil)");

    QT_BT_MAC_AUTORELEASEPOOL;

    CBService *const cbService = [ch service];
    const QBluetoothUuid serviceUuid(OSXBluetooth::qt_uuid(cbService.UUID));
    if (!discoveredServices.contains(serviceUuid)) {
        qCDebug(QT_BT_OSX) << "QLowEnergyControllerPrivateOSX::characteristicWriteNotification(), "
                              "unknown service uuid: " << serviceUuid;
        return;
    }

    ServicePrivate service(discoveredServices.value(serviceUuid));
    Q_ASSERT_X(service->startHandle, "characteristicWriteNotification",
               "invalid service handle (0)");

    const QLowEnergyHandle charHandle =
        qt_findCharacteristicHandle(service->startHandle, cbService, ch);

    if (!charHandle) {
        qCDebug(QT_BT_OSX) << "QLowEnergyControllerPrivateOSX::characteristicWriteNotification(), "
                              "unknown characteristic";
        return;
    }

    QLowEnergyCharacteristic characteristic(characteristicForHandle(charHandle));
    if (!characteristic.isValid()) {
        qCWarning(QT_BT_OSX) << "QLowEnergyControllerPrivateOSX::characteristicWriteNotification(), "
                                "unknown characteristic";
        return;
    }

    // TODO: check that this 'value' is what we need!
    const QByteArray data(OSXBluetooth::qt_bytearray([ch value]));
    updateValueOfCharacteristic(charHandle, data, false);
    emit service->characteristicWritten(characteristic, data);
}

void QLowEnergyControllerPrivateOSX::disconnected()
{
    controllerState = QLowEnergyController::UnconnectedState;

    if (!isConnecting) {
        emit q_ptr->stateChanged(QLowEnergyController::UnconnectedState);
        emit q_ptr->disconnected();
    }
}

void QLowEnergyControllerPrivateOSX::error(QLowEnergyController::Error errorCode)
{
    // Errors reported during connect and general errors.

    // We're still in connectToDevice,
    // some error was reported synchronously.
    // Return, the error will be correctly set later
    // by connectToDevice.
    if (isConnecting) {
        lastError = errorCode;
        return;
    }

    setErrorDescription(errorCode);
    emit q_ptr->error(lastError);

    if (controllerState == QLowEnergyController::ConnectingState) {
        controllerState = QLowEnergyController::UnconnectedState;
        emit q_ptr->stateChanged(controllerState);
    } else if (controllerState == QLowEnergyController::DiscoveringState) {
        controllerState = QLowEnergyController::ConnectedState;
        emit q_ptr->stateChanged(controllerState);
    } // In any other case we stay in Discovered, it's
      // a service/characteristic - related error.
}

void QLowEnergyControllerPrivateOSX::error(const QBluetoothUuid &serviceUuid,
                                           QLowEnergyController::Error errorCode)
{
    // Errors reported while discovering service details etc.
    Q_UNUSED(errorCode) // TODO: setError?

    // We failed to discover any characteristics/descriptors.
    if (discoveredServices.contains(serviceUuid)) {
        ServicePrivate qtService(discoveredServices.value(serviceUuid));
        qtService->stateChanged(QLowEnergyService::InvalidService);
    } else {
        qCDebug(QT_BT_OSX) << "QLowEnergyControllerPrivateOSX::error(), "
                              "error reported for unknown service "<<serviceUuid;
    }
}

void QLowEnergyControllerPrivateOSX::error(const QBluetoothUuid &serviceUuid,
                                           QLowEnergyHandle charHandle,
                                           QLowEnergyService::ServiceError errorCode)
{
    Q_UNUSED(charHandle)

    if (!discoveredServices.contains(serviceUuid)) {
        qCDebug(QT_BT_OSX) << "QLowEnergyControllerPrivateOSX::error(), "
                              "unknown service uuid: " << serviceUuid;
        return;
    }

    ServicePrivate service(discoveredServices.value(serviceUuid));
    service->setError(errorCode);
}

void QLowEnergyControllerPrivateOSX::connectToDevice()
{
    Q_ASSERT_X(isValid(), "connectToDevice", "invalid private controller");
    Q_ASSERT_X(controllerState == QLowEnergyController::UnconnectedState,
               "connectToDevice", "invalid state");
    Q_ASSERT_X(!deviceUuid.isNull(), "connectToDevice",
               "invalid private controller (no device uuid)");
    Q_ASSERT_X(!isConnecting, "connectToDevice",
               "recursive connectToDevice call");

    setErrorDescription(QLowEnergyController::NoError);

    isConnecting = true;// Do not emit signals if some callback is executed synchronously.
    controllerState = QLowEnergyController::ConnectingState;
    const QLowEnergyController::Error status = [centralManager connectToDevice:deviceUuid];
    isConnecting = false;

    if (status == QLowEnergyController::NoError && lastError == QLowEnergyController::NoError) {
        emit q_ptr->stateChanged(controllerState);
        if (controllerState == QLowEnergyController::ConnectedState) {
            // If a peripheral is connected already from the Core Bluetooth's
            // POV:
            emit q_ptr->connected();
        } else if (controllerState == QLowEnergyController::UnconnectedState) {
            // Ooops, tried to connect, got peripheral disconnect instead -
            // this happens with Core Bluetooth.
            emit q_ptr->disconnected();
        }
    } else if (status != QLowEnergyController::NoError) {
        error(status);
    } else {
        // Re-set the error/description and emit.
        error(lastError);
    }
}

void QLowEnergyControllerPrivateOSX::discoverServices()
{
    Q_ASSERT_X(isValid(), "discoverServices", "invalid private controller");
    Q_ASSERT_X(controllerState != QLowEnergyController::UnconnectedState,
               "discoverServices", "not connected to peripheral");

    controllerState = QLowEnergyController::DiscoveringState;
    emit q_ptr->stateChanged(QLowEnergyController::DiscoveringState);
    [centralManager discoverServices];
}

void QLowEnergyControllerPrivateOSX::discoverServiceDetails(const QBluetoothUuid &serviceUuid)
{
    Q_ASSERT_X(isValid(), "discoverServiceDetails", "invalid private controller");

    if (controllerState != QLowEnergyController::DiscoveredState) {
        qCWarning(QT_BT_OSX) << "QLowEnergyControllerPrivateOSX::discoverServiceDetails(), "
                                "can not discover service details in the current state, "
                                "QLowEnergyController::DiscoveredState is expected";
        return;
    }

    if (!discoveredServices.contains(serviceUuid)) {
        qCWarning(QT_BT_OSX) << "QLowEnergyControllerPrivateOSX::discoverServiceDetails(), "
                                "unknown service: " << serviceUuid;
        return;
    }

    ServicePrivate qtService(discoveredServices.value(serviceUuid));
    if ([centralManager discoverServiceDetails:serviceUuid]) {
        qtService->stateChanged(QLowEnergyService::DiscoveringServices);
    } else {
        // The error is returned by CentralManager - no
        // service with a given UUID found on a peripheral.
        qtService->stateChanged(QLowEnergyService::InvalidService);
    }
}

void QLowEnergyControllerPrivateOSX::setNotifyValue(QSharedPointer<QLowEnergyServicePrivate> service,
                                                    QLowEnergyHandle charHandle, const QByteArray &newValue)
{
    Q_UNUSED(service)
    Q_UNUSED(charHandle)
    Q_UNUSED(newValue)
}

void QLowEnergyControllerPrivateOSX::writeCharacteristic(QSharedPointer<QLowEnergyServicePrivate> service,
                                                         QLowEnergyHandle charHandle, const QByteArray &newValue,
                                                         bool writeWithResponse)
{
    Q_ASSERT_X(!service.isNull(), "writeCharacteristic", "invalid service (null)");

    if (!isValid()) {
        qCWarning(QT_BT_OSX) << "QLowEnergyControllerPrivateOSX::writeCharacteristic(), "
                                "invalid controller";
        return;
    }

    // We can work only with services, found on a given peripheral
    // (== created by the given LE controller),
    // otherwise we can not write anything at all.
    if (!discoveredServices.contains(service->uuid)) {
        qCWarning(QT_BT_OSX) << "QLowEnergyControllerPrivateOSX::writeCharacteristic(), "
                                "no service with uuid: " << service << "found";
        return;
    }

    if (!service->characteristicList.contains(charHandle)) {
        qCDebug(QT_BT_OSX) << "QLowEnergyControllerPrivateOSX::writeCharacteristic(), "
                              "no characteristic with handle: " << charHandle << "found";
        return;
    }

    const bool result = [centralManager write:newValue
                                        charHandle:charHandle
                                        withResponse:writeWithResponse];
    if (!result)
        service->setError(QLowEnergyService::CharacteristicWriteError);
}

quint16 QLowEnergyControllerPrivateOSX::updateValueOfCharacteristic(QLowEnergyHandle charHandle,
                                                                    const QByteArray &value,
                                                                    bool appendValue)
{
    QSharedPointer<QLowEnergyServicePrivate> service = serviceForHandle(charHandle);
    if (!service.isNull() && service->characteristicList.contains(charHandle)) {
        if (appendValue)
            service->characteristicList[charHandle].value += value;
        else
            service->characteristicList[charHandle].value = value;

        return service->characteristicList[charHandle].value.size();
    }

    return 0;
}

void QLowEnergyControllerPrivateOSX::writeDescriptor(QSharedPointer<QLowEnergyServicePrivate> service,
                                                     QLowEnergyHandle charHandle, const QLowEnergyHandle descriptorHandle,
                                                     const QByteArray &newValue)
{
    Q_UNUSED(service)
    Q_UNUSED(charHandle)
    Q_UNUSED(descriptorHandle)
    Q_UNUSED(newValue)
}

QSharedPointer<QLowEnergyServicePrivate> QLowEnergyControllerPrivateOSX::serviceForHandle(QLowEnergyHandle handle)
{
    foreach (QSharedPointer<QLowEnergyServicePrivate> service, discoveredServices.values()) {
        if (service->startHandle <= handle && handle <= service->endHandle)
            return service;
    }

    return QSharedPointer<QLowEnergyServicePrivate>();
}

QLowEnergyCharacteristic QLowEnergyControllerPrivateOSX::characteristicForHandle(QLowEnergyHandle charHandle)
{
    QSharedPointer<QLowEnergyServicePrivate> service(serviceForHandle(charHandle));
    if (service.isNull())
        return QLowEnergyCharacteristic();

    if (service->characteristicList.isEmpty())
        return QLowEnergyCharacteristic();

    // Check whether it is the handle of a characteristic header
    if (service->characteristicList.contains(charHandle))
        return QLowEnergyCharacteristic(service, charHandle);

    // Check whether it is the handle of the characteristic value or its descriptors
    QList<QLowEnergyHandle> charHandles(service->characteristicList.keys());
    std::sort(charHandles.begin(), charHandles.end());

    for (int i = charHandles.size() - 1; i >= 0; --i) {
        if (charHandles.at(i) > charHandle)
            continue;

        return QLowEnergyCharacteristic(service, charHandles.at(i));
    }

    return QLowEnergyCharacteristic();
}

void QLowEnergyControllerPrivateOSX::setErrorDescription(QLowEnergyController::Error errorCode)
{
    // This function does not emit!

    lastError = errorCode;

    switch (lastError) {
    case QLowEnergyController::NoError:
        errorString.clear();
        break;
    case QLowEnergyController::UnknownRemoteDeviceError:
        errorString = QLowEnergyController::tr("Remote device cannot be found");
        break;
    case QLowEnergyController::InvalidBluetoothAdapterError:
        errorString = QLowEnergyController::tr("Cannot find local adapter");
        break;
    case QLowEnergyController::NetworkError:
        errorString = QLowEnergyController::tr("Error occurred during connection I/O");
        break;
    case QLowEnergyController::UnknownError:
    default:
        errorString = QLowEnergyController::tr("Unknown Error");
        break;
    }
}

void QLowEnergyControllerPrivateOSX::invalidateServices()
{
    foreach (const QSharedPointer<QLowEnergyServicePrivate> service, discoveredServices.values()) {
        service->setController(Q_NULLPTR);
        service->setState(QLowEnergyService::InvalidService);
    }

    lastValidHandle = 0;
    discoveredServices.clear();
}

QLowEnergyController::QLowEnergyController(const QBluetoothAddress &remoteAddress,
                                           QObject *parent)
    : QObject(parent),
      d_ptr(new QLowEnergyControllerPrivateOSX(this))
{
    Q_UNUSED(remoteAddress)

    qCWarning(QT_BT_OSX) << "QLowEnergyController::QLowEnergyController(), "
                            "construction with remote address is not supported!";
}

QLowEnergyController::QLowEnergyController(const QBluetoothDeviceInfo &remoteDevice,
                                           QObject *parent)
    : QObject(parent),
      d_ptr(new QLowEnergyControllerPrivateOSX(this, remoteDevice))
{
    // That's the only "real" ctor - with Core Bluetooth we need a _valid_ deviceUuid
    // from 'remoteDevice'.
}

QLowEnergyController::QLowEnergyController(const QBluetoothAddress &remoteAddress,
                                           const QBluetoothAddress &localAddress,
                                           QObject *parent)
    : QObject(parent),
      d_ptr(new QLowEnergyControllerPrivateOSX(this))
{
    OSX_D_PTR;

    osx_d_ptr->remoteAddress = remoteAddress;
    osx_d_ptr->localAddress = localAddress;

    qCWarning(QT_BT_OSX) << "QLowEnergyController::QLowEnergyController(), "
                            "construction with remote/local addresses is not supported!";
}

QLowEnergyController::~QLowEnergyController()
{
    // Deleting a peripheral will also disconnect.
    delete d_ptr;
}

QBluetoothAddress QLowEnergyController::localAddress() const
{
    OSX_D_PTR;

    return osx_d_ptr->localAddress;
}

QBluetoothAddress QLowEnergyController::remoteAddress() const
{
    OSX_D_PTR;

    return osx_d_ptr->remoteAddress;
}

QLowEnergyController::ControllerState QLowEnergyController::state() const
{
    OSX_D_PTR;

    return osx_d_ptr->controllerState;
}

QLowEnergyController::RemoteAddressType QLowEnergyController::remoteAddressType() const
{
    OSX_D_PTR;

    return osx_d_ptr->addressType;
}

void QLowEnergyController::setRemoteAddressType(RemoteAddressType type)
{
    Q_UNUSED(type)

    OSX_D_PTR;

    osx_d_ptr->addressType = type;
}

void QLowEnergyController::connectToDevice()
{
    OSX_D_PTR;

    // A memory allocation problem.
    if (!osx_d_ptr->isValid())
        return osx_d_ptr->error(UnknownError);

    // No QBluetoothDeviceInfo provided during construction.
    if (osx_d_ptr->deviceUuid.isNull())
        return osx_d_ptr->error(UnknownRemoteDeviceError);

    if (osx_d_ptr->controllerState != UnconnectedState)
        return;

    osx_d_ptr->connectToDevice();
}

void QLowEnergyController::disconnectFromDevice()
{
    if (state() == UnconnectedState || state() == ClosingState)
        return;

    OSX_D_PTR;

    if (osx_d_ptr->isValid()) {
        const ControllerState oldState = osx_d_ptr->controllerState;

        osx_d_ptr->controllerState = ClosingState;
        emit stateChanged(ClosingState);
        osx_d_ptr->invalidateServices();
        [osx_d_ptr->centralManager disconnectFromDevice];

        if (oldState == ConnectingState) {
            // With a pending connect attempt there is no
            // guarantee we'll ever have didDisconnect callback,
            // set the state here and now to make sure we still
            // can connect.
            osx_d_ptr->controllerState = UnconnectedState;
            emit stateChanged(UnconnectedState);
        }
    }
}

void QLowEnergyController::discoverServices()
{
    if (state() != ConnectedState)
        return;

    OSX_D_PTR;

    osx_d_ptr->discoverServices();
}

QList<QBluetoothUuid> QLowEnergyController::services() const
{
    OSX_D_PTR;

    return osx_d_ptr->discoveredServices.keys();
}

QLowEnergyService *QLowEnergyController::createServiceObject(const QBluetoothUuid &serviceUuid,
                                                             QObject *parent)
{
    OSX_D_PTR;

    if (!osx_d_ptr->discoveredServices.contains(serviceUuid))
        return Q_NULLPTR;

    return new QLowEnergyService(osx_d_ptr->discoveredServices.value(serviceUuid), parent);
}

QLowEnergyController::Error QLowEnergyController::error() const
{
    OSX_D_PTR;

    return osx_d_ptr->lastError;
}

QString QLowEnergyController::errorString() const
{
    OSX_D_PTR;

    return osx_d_ptr->errorString;
}

QT_END_NAMESPACE
