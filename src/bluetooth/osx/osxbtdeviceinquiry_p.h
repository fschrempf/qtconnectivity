/****************************************************************************
**
** Copyright (C) 2014 Digia Plc and/or its subsidiary(-ies).
** Contact: http://www.qt-project.org/legal
**
** This file is part of the QtBluetooth module of the Qt Toolkit.
**
** $QT_BEGIN_LICENSE:LGPL$
** Commercial License Usage
** Licensees holding valid commercial Qt licenses may use this file in
** accordance with the commercial license agreement provided with the
** Software or, alternatively, in accordance with the terms contained in
** a written agreement between you and Digia.  For licensing terms and
** conditions see http://qt.digia.com/licensing.  For further information
** use the contact form at http://qt.digia.com/contact-us.
**
** GNU Lesser General Public License Usage
** Alternatively, this file may be used under the terms of the GNU Lesser
** General Public License version 2.1 as published by the Free Software
** Foundation and appearing in the file LICENSE.LGPL included in the
** packaging of this file.  Please review the following information to
** ensure the GNU Lesser General Public License version 2.1 requirements
** will be met: http://www.gnu.org/licenses/old-licenses/lgpl-2.1.html.
**
** In addition, as a special exception, Digia gives you certain additional
** rights.  These rights are described in the Digia Qt LGPL Exception
** version 1.1, included in the file LGPL_EXCEPTION.txt in this package.
**
** GNU General Public License Usage
** Alternatively, this file may be used under the terms of the GNU
** General Public License version 3.0 as published by the Free Software
** Foundation and appearing in the file LICENSE.GPL included in the
** packaging of this file.  Please review the following information to
** ensure the GNU General Public License version 3.0 requirements will be
** met: http://www.gnu.org/copyleft/gpl.html.
**
**
** $QT_END_LICENSE$
**
****************************************************************************/

#ifndef OSXBTDEVICEINQUIRY_P_H
#define OSXBTDEVICEINQUIRY_P_H

#include <QtCore/qglobal.h>

// We have to import objc code (it does not have inclusion guards).
#import <IOBluetooth/objc/IOBluetoothDeviceInquiry.h>

#include <Foundation/Foundation.h>
#include <IOKit/IOReturn.h>

QT_BEGIN_NAMESPACE

namespace OSXBluetooth {

class DeviceInquiryDelegate {
public:
    virtual ~DeviceInquiryDelegate();

    virtual void inquiryFinished(IOBluetoothDeviceInquiry *inq) = 0;
    virtual void error(IOBluetoothDeviceInquiry *inq, IOReturn error) = 0;
    virtual void deviceFound(IOBluetoothDeviceInquiry *inq, IOBluetoothDevice *device) = 0;
};

}

QT_END_NAMESPACE

@interface QT_MANGLE_NAMESPACE(OSXBTDeviceInquiry) : NSObject<IOBluetoothDeviceInquiryDelegate>
{
    IOBluetoothDeviceInquiry *m_inquiry;
    bool m_active;
    QT_PREPEND_NAMESPACE(OSXBluetooth::DeviceInquiryDelegate) *m_delegate;//C++ "delegate"
}

- (id)initWithDelegate:(QT_PREPEND_NAMESPACE(OSXBluetooth::DeviceInquiryDelegate) *)delegate;
- (void)dealloc;

- (bool)isActive;
- (IOReturn)start;
- (IOReturn)stop;

//Obj-C delegate:
- (void)deviceInquiryComplete:(IOBluetoothDeviceInquiry *)sender
        error:(IOReturn)error aborted:(BOOL)aborted;

- (void)deviceInquiryDeviceFound:(IOBluetoothDeviceInquiry *)sender
        device:(IOBluetoothDevice *)device;

- (void)deviceInquiryDeviceNameUpdated:(IOBluetoothDeviceInquiry *)sender
        device:(IOBluetoothDevice*)device devicesRemaining:(uint32_t)devicesRemaining;

- (void)deviceInquiryStarted:(IOBluetoothDeviceInquiry *)sender;

- (void)deviceInquiryUpdatingDeviceNamesStarted:(IOBluetoothDeviceInquiry *)sender
        devicesRemaining:(uint32_t)devicesRemaining;

@end

#endif
