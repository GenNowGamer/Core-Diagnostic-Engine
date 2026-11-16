using System.Windows.Controls;
using ToolkitGUI.ViewModels;

namespace ToolkitGUI.Views
{
    public partial class StorageRecoveryView : UserControl
    {
        public StorageRecoveryView()
        {
            InitializeComponent();
            DataContext = new StorageRecoveryViewModel();
        }
    }
}
