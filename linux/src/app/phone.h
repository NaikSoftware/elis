#pragma once

#include <QImage>
#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QProcess>
#include <QStringList>

#include <functional>

class QWidget;

// The phone relay without a terminal: the app runs `elisctl mobile serve` as its child, one for all windows, and starts
// it again at launch while it is switched on. The switch, the port and the address the code shows live in
// <state>/mobile/desktop.json.
class PhoneRelay : public QObject
{
    Q_OBJECT
public:
    static PhoneRelay *instance();
    ~PhoneRelay() override;

    bool enabled() const { return m_on; }
    bool listening() const { return !m_links.isEmpty(); }
    quint16 port() const { return m_port; }
    QStringList hosts() const;   // one per address serve offered, the best guess first
    QString host() const;        // the address the code shows: the chosen one, else the first offered
    QString link() const;        // the pairing link for host(); empty until serve is listening
    QString error() const { return m_error; }
    QString lastEvent() const { return m_event; }
    QString bluetooth() const { return m_bluetooth; } // serve's `phone.status` value, empty until it reports one
    QString bluetoothText() const;

    void setEnabled(bool on); // on means "try to be listening": on again restarts only a relay that failed
    void setPort(quint16 port);
    void setHost(const QString &host);
    bool revoke(QString *error); // a new token: paired phones are cut off and the code changes

    QJsonObject status() const;   // ControlPhoneStatus, with the link while listening
    QJsonObject readback() const; // tree.phone: on, listening, port, host, bluetooth
    // done runs once the relay listens and reported Bluetooth, failed, is off, or after startLimitMs
    void whenSettled(std::function<void()> done);
    static constexpr int startLimitMs = 10000;

Q_SIGNALS:
    void changed();
    // phone.connected | disconnected | refused {ip}, and phone.attached | detached | claimed | released {paneID, ip?}: the
    // relay's lines, and a detach and release for each viewer and lead still counted when it stops
    void phoneEvent(const QString &kind, const QJsonObject &payload);

private:
    PhoneRelay();
    void start();
    void stop();
    void save() const;
    void releaseViewers();

    QPointer<QProcess> m_proc;
    bool m_on = false;
    quint16 m_port = 8765;
    QString m_host;
    QStringList m_links;
    QString m_error, m_event, m_bluetooth, m_bluetoothText;
};

// phone.*, the Mac's ControlServer+Phone: reply runs once, now or when an on, port or revoke settled
void phoneCommand(const QJsonObject &request, const std::function<void(const QJsonObject &)> &reply);

QString pairLinkWithHost(const QString &link, const QString &host, quint16 port);
QImage qrImage(const QString &text); // one pixel per module, black on white, four modules of quiet zone
void showPhoneDialog(QWidget *parent);
